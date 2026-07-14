import Foundation
import Synchronization

private final class _WebInspectorStateMailbox<State: Sendable>:
    @unchecked Sendable
{
    private enum Storage {
        case idle
        case buffered(State, finishAfterDelivery: Bool)
        case waiting(CheckedContinuation<State?, Never>)
        case finished
    }

    private let storage: Mutex<Storage>
    private let onFinish: @Sendable () -> Void

    init(
        initial: State,
        onFinish: @escaping @Sendable () -> Void
    ) {
        storage = Mutex(.buffered(initial, finishAfterDelivery: false))
        self.onFinish = onFinish
    }

    func next() async -> State? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = storage.withLock { storage -> State?? in
                    switch storage {
                    case .idle:
                        storage = .waiting(continuation)
                        return nil
                    case let .buffered(value, finishAfterDelivery):
                        storage = finishAfterDelivery ? .finished : .idle
                        return .some(.some(value))
                    case .waiting, .finished:
                        return .some(.none)
                    }
                }
                if let result { continuation.resume(returning: result) }
            }
        } onCancel: {
            finish()
        }
    }

    func publish(_ value: State) {
        let waiter = storage.withLock {
            storage -> CheckedContinuation<State?, Never>? in
            switch storage {
            case .idle, .buffered:
                storage = .buffered(value, finishAfterDelivery: false)
                return nil
            case let .waiting(waiter):
                storage = .idle
                return waiter
            case .finished:
                return nil
            }
        }
        waiter?.resume(returning: value)
    }

    func finish() {
        let waiter = storage.withLock {
            storage -> CheckedContinuation<State?, Never>? in
            switch storage {
            case .idle:
                storage = .finished
                return nil
            case let .buffered(value, _):
                storage = .buffered(value, finishAfterDelivery: true)
                return nil
            case let .waiting(waiter):
                storage = .finished
                return waiter
            case .finished:
                return nil
            }
        }
        waiter?.resume(returning: nil)
        onFinish()
    }
}

private final class _WebInspectorStateSubscription<State: Sendable>:
    @unchecked Sendable
{
    let mailbox: _WebInspectorStateMailbox<State>

    init(mailbox: _WebInspectorStateMailbox<State>) {
        self.mailbox = mailbox
    }

    deinit { mailbox.finish() }
}

package final class _WebInspectorStatePublisher<State: Sendable>:
    @unchecked Sendable
{
    private struct Storage {
        var current: State
        var subscriptions: [UUID: _WebInspectorStateMailbox<State>] = [:]
        var isFinished = false
    }

    private let storage: Mutex<Storage>

    package init(_ initial: State) {
        storage = Mutex(Storage(current: initial))
    }

    package var current: State {
        storage.withLock(\.current)
    }

    package func updates() -> WebInspectorStateUpdates<State> {
        WebInspectorStateUpdates(publisher: self)
    }

    package func publish(_ state: State) {
        let subscriptions = storage.withLock { storage in
            guard !storage.isFinished else {
                return [
                    _WebInspectorStateMailbox<State>
                ]()
            }
            storage.current = state
            return Array(storage.subscriptions.values)
        }
        for subscription in subscriptions { subscription.publish(state) }
    }

    package func finish() {
        let subscriptions = storage.withLock { storage in
            guard !storage.isFinished else {
                return [
                    _WebInspectorStateMailbox<State>
                ]()
            }
            storage.isFinished = true
            defer { storage.subscriptions.removeAll(keepingCapacity: false) }
            return Array(storage.subscriptions.values)
        }
        for subscription in subscriptions { subscription.finish() }
    }

    fileprivate func subscribe() -> _WebInspectorStateSubscription<State> {
        let id = UUID()
        let result = storage.withLock {
            storage -> (
                _WebInspectorStateSubscription<State>,
                Bool
            ) in
            let mailbox = _WebInspectorStateMailbox(
                initial: storage.current
            ) { [weak self] in
                self?.remove(id)
            }
            if !storage.isFinished {
                storage.subscriptions[id] = mailbox
            }
            return (
                _WebInspectorStateSubscription(mailbox: mailbox),
                storage.isFinished
            )
        }
        if result.1 { result.0.mailbox.finish() }
        return result.0
    }

    private func remove(_ id: UUID) {
        storage.withLock { $0.subscriptions[id] = nil }
    }
}

/// A bounded, last-value-first state sequence.
public struct WebInspectorStateUpdates<State>: AsyncSequence, Sendable
where State: Sendable {
    public typealias Element = State
    public typealias Failure = Never

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let subscription: _WebInspectorStateSubscription<State>

        fileprivate init(
            subscription: _WebInspectorStateSubscription<State>
        ) {
            self.subscription = subscription
        }

        public mutating func next() async -> State? {
            await subscription.mailbox.next()
        }
    }

    private let publisher: _WebInspectorStatePublisher<State>

    package init(publisher: _WebInspectorStatePublisher<State>) {
        self.publisher = publisher
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(subscription: publisher.subscribe())
    }
}

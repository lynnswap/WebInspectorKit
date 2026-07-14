import Foundation
import Synchronization

package final class _WebInspectorFetchedResultsUpdateMailbox<
    ItemID: Hashable & Sendable
>: @unchecked Sendable {
    package typealias Element = WebInspectorFetchedResultsUpdate<ItemID>

    private enum State {
        case idle
        case buffered(Element)
        case waiting(CheckedContinuation<Element?, Never>)
        case finished
    }

    private let state: Mutex<State>
    private let onFinish: @Sendable () -> Void

    package init(
        initial: Element?,
        onFinish: @escaping @Sendable () -> Void
    ) {
        state = Mutex(initial.map(State.buffered) ?? .idle)
        self.onFinish = onFinish
    }

    package func next() async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Element?? in
                    switch state {
                    case .idle:
                        state = .waiting(continuation)
                        return nil
                    case let .buffered(element):
                        state = .idle
                        return .some(.some(element))
                    case .waiting:
                        return .some(.none)
                    case .finished:
                        return .some(.none)
                    }
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: {
            finish()
        }
    }

    package func publish(
        _ element: Element,
        latestReset: Element
    ) {
        let waiter = state.withLock {
            state -> CheckedContinuation<Element?, Never>? in
            switch state {
            case .idle:
                state = .buffered(element)
                return nil
            case .buffered:
                state = .buffered(latestReset)
                return nil
            case let .waiting(waiter):
                state = .idle
                return waiter
            case .finished:
                return nil
            }
        }
        waiter?.resume(returning: element)
    }

    package func finish() {
        let waiter = state.withLock {
            state -> CheckedContinuation<Element?, Never>? in
            guard case .finished = state else {
                defer { state = .finished }
                if case let .waiting(waiter) = state {
                    return waiter
                }
                return nil
            }
            return nil
        }
        waiter?.resume(returning: nil)
        onFinish()
    }
}

package final class _WebInspectorFetchedResultsUpdateSubscription<
    ItemID: Hashable & Sendable
>: @unchecked Sendable {
    package let mailbox: _WebInspectorFetchedResultsUpdateMailbox<ItemID>

    package init(
        mailbox: _WebInspectorFetchedResultsUpdateMailbox<ItemID>
    ) {
        self.mailbox = mailbox
    }

    deinit {
        mailbox.finish()
    }
}

package final class _WebInspectorFetchedResultsUpdatePublisher<
    ItemID: Hashable & Sendable
>: @unchecked Sendable {
    package typealias Element = WebInspectorFetchedResultsUpdate<ItemID>

    private struct SuccessfulState {
        let revision: WebInspectorFetchedResultsRevision
        let snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    }

    private struct State {
        var successfulState: SuccessfulState?
        var subscribers: [UUID: _WebInspectorFetchedResultsUpdateMailbox<ItemID>] = [:]
        var isClosed = false
    }

    private let state = Mutex(State())

    package init() {}

    package func sequence()
        -> WebInspectorFetchedResultsUpdateSequence<ItemID>
    {
        WebInspectorFetchedResultsUpdateSequence(publisher: self)
    }

    package func publish(
        _ element: Element,
        revision: WebInspectorFetchedResultsRevision,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    ) {
        let output = state.withLock {
            state -> (
                [_WebInspectorFetchedResultsUpdateMailbox<ItemID>],
                Element
            )? in
            guard !state.isClosed else { return nil }
            state.successfulState = SuccessfulState(
                revision: revision,
                snapshot: snapshot
            )
            return (
                Array(state.subscribers.values),
                .reset(revision: revision, snapshot: snapshot)
            )
        }
        guard let (subscribers, latestReset) = output else { return }
        for subscriber in subscribers {
            subscriber.publish(element, latestReset: latestReset)
        }
    }

    package func subscribe()
        -> _WebInspectorFetchedResultsUpdateSubscription<ItemID>
    {
        let id = UUID()
        let result = state.withLock {
            state -> (
                _WebInspectorFetchedResultsUpdateSubscription<ItemID>,
                Bool
            ) in
            let initial = state.successfulState.map {
                Element.initial(
                    revision: $0.revision,
                    snapshot: $0.snapshot
                )
            }
            let mailbox = _WebInspectorFetchedResultsUpdateMailbox(
                initial: initial
            ) { [weak self] in
                self?.removeSubscriber(id)
            }
            if !state.isClosed {
                state.subscribers[id] = mailbox
            }
            return (
                _WebInspectorFetchedResultsUpdateSubscription(
                    mailbox: mailbox
                ),
                state.isClosed
            )
        }
        if result.1 { result.0.mailbox.finish() }
        return result.0
    }

    package func finish() {
        let subscribers = state.withLock { state in
            guard !state.isClosed else {
                return [
                    _WebInspectorFetchedResultsUpdateMailbox<ItemID>
                ]()
            }
            state.isClosed = true
            state.successfulState = nil
            defer { state.subscribers.removeAll(keepingCapacity: false) }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        state.withLock { state in
            state.subscribers[id] = nil
        }
    }
}

/// A multi-subscriber, nonfailing stream of one controller's atomic updates.
///
/// Each iterator owns a capacity-one semantic mailbox. Falling behind replaces
/// queued deltas with the latest complete reset, so a subscriber never observes
/// a revision gap and memory use does not grow with protocol traffic.
public struct WebInspectorFetchedResultsUpdateSequence<
    ItemID: Hashable & Sendable
>: AsyncSequence, Sendable {
    public typealias Element = WebInspectorFetchedResultsUpdate<ItemID>
    public typealias Failure = Never

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let subscription: _WebInspectorFetchedResultsUpdateSubscription<ItemID>

        package init(
            subscription:
                _WebInspectorFetchedResultsUpdateSubscription<ItemID>
        ) {
            self.subscription = subscription
        }

        public mutating func next() async -> Element? {
            await subscription.mailbox.next()
        }
    }

    private let publisher: _WebInspectorFetchedResultsUpdatePublisher<ItemID>

    package init(
        publisher: _WebInspectorFetchedResultsUpdatePublisher<ItemID>
    ) {
        self.publisher = publisher
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(subscription: publisher.subscribe())
    }
}

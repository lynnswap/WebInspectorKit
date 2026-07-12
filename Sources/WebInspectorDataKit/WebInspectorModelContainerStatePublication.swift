import Synchronization

package final class WebInspectorModelContainerStatePublication: Sendable {
    package typealias State = WebInspectorModelContainer.State

    private enum PublishDecision {
        case duplicate(revision: UInt64)
        case deliver(
            revision: UInt64,
            subscribers: [WebInspectorModelContainerStateMailbox]
        )
    }

    private struct Storage {
        var revision: UInt64 = 0
        var current: State = .detached
        var isFinished = false
        var nextSubscriberID: UInt64 = 0
        var subscribers: [UInt64: WebInspectorModelContainerStateMailbox] = [:]
    }

    private let storage = Mutex(Storage())

    package var current: State {
        storage.withLock { $0.current }
    }

    package var revision: UInt64 {
        storage.withLock { $0.revision }
    }

    package init() {}

    package func subscribe()
        -> WebInspectorModelContainer.StateUpdateSequence
    {
        let subscription = storage.withLock { storage in
            precondition(
                storage.nextSubscriberID < UInt64.max,
                "Model Container state publication exhausted subscriber identifiers."
            )
            storage.nextSubscriberID += 1
            let subscriberID = storage.nextSubscriberID
            let mailbox = WebInspectorModelContainerStateMailbox(
                revision: storage.revision,
                state: storage.current,
                finishesAfterPendingState: storage.isFinished
            )
            if !storage.isFinished {
                storage.subscribers[subscriberID] = mailbox
            }
            return WebInspectorModelContainerStateSubscription(
                id: subscriberID,
                mailbox: mailbox,
                publication: self
            )
        }
        return WebInspectorModelContainer.StateUpdateSequence(
            subscription: subscription
        )
    }

    @discardableResult
    package func publish(_ state: State) -> UInt64 {
        precondition(
            state != .closed,
            "Only finish() can publish the terminal Model Container state."
        )
        let decision = storage.withLock { storage -> PublishDecision in
            precondition(
                !storage.isFinished,
                "A closed Model Container cannot publish another state."
            )
            guard storage.current != state else {
                return .duplicate(revision: storage.revision)
            }
            precondition(
                storage.revision < UInt64.max,
                "Model Container state publication exhausted revisions."
            )
            storage.revision += 1
            storage.current = state
            return .deliver(
                revision: storage.revision,
                subscribers: Array(storage.subscribers.values)
            )
        }
        switch decision {
        case let .duplicate(revision):
            return revision
        case let .deliver(revision, subscribers):
            for subscriber in subscribers {
                subscriber.offer(
                    revision: revision,
                    state: state,
                    finishesAfterState: false
                )
            }
            return revision
        }
    }

    @discardableResult
    package func finish() -> UInt64 {
        let delivery = storage.withLock {
            storage -> (
                revision: UInt64,
                subscribers: [WebInspectorModelContainerStateMailbox]
            )? in
            guard !storage.isFinished else {
                return nil
            }
            precondition(
                storage.revision < UInt64.max,
                "Model Container state publication exhausted revisions."
            )
            storage.revision += 1
            storage.current = .closed
            storage.isFinished = true
            let subscribers = Array(storage.subscribers.values)
            storage.subscribers.removeAll(keepingCapacity: false)
            return (storage.revision, subscribers)
        }
        guard let delivery else {
            return storage.withLock { $0.revision }
        }
        for subscriber in delivery.subscribers {
            subscriber.offer(
                revision: delivery.revision,
                state: .closed,
                finishesAfterState: true
            )
        }
        return delivery.revision
    }

    fileprivate func removeSubscriber(_ id: UInt64) {
        let mailbox = storage.withLock { storage in
            storage.subscribers.removeValue(forKey: id)
        }
        mailbox?.cancel()
    }
}

package final class WebInspectorModelContainerStateSubscription: Sendable {
    package let mailbox: WebInspectorModelContainerStateMailbox

    private let id: UInt64
    private let publication: WebInspectorModelContainerStatePublication

    package init(
        id: UInt64,
        mailbox: WebInspectorModelContainerStateMailbox,
        publication: WebInspectorModelContainerStatePublication
    ) {
        self.id = id
        self.mailbox = mailbox
        self.publication = publication
    }

    deinit {
        publication.removeSubscriber(id)
    }
}

package final class WebInspectorModelContainerStateMailbox: Sendable {
    package typealias ContainerState = WebInspectorModelContainer.State

    private struct PendingState: Sendable {
        let revision: UInt64
        let state: ContainerState
    }

    private struct Storage {
        var pending: PendingState?
        var lastDeliveredRevision: UInt64?
        var finishesAfterPendingState: Bool
        var isTerminal = false
        var iteratorWasCreated = false
        var waiter: CheckedContinuation<ContainerState?, Never>?
    }

    private let storage: Mutex<Storage>

    package init(
        revision: UInt64,
        state: ContainerState,
        finishesAfterPendingState: Bool
    ) {
        storage = Mutex(
            Storage(
                pending: PendingState(revision: revision, state: state),
                lastDeliveredRevision: nil,
                finishesAfterPendingState: finishesAfterPendingState
            ))
    }

    package func claimIterator() {
        storage.withLock { storage in
            precondition(
                !storage.iteratorWasCreated,
                "A Model Container state sequence supports one iterator."
            )
            storage.iteratorWasCreated = true
        }
    }

    package func offer(
        revision: UInt64,
        state: ContainerState,
        finishesAfterState: Bool
    ) {
        let waiter = storage.withLock {
            storage
                -> CheckedContinuation<ContainerState?, Never>? in
            guard !storage.isTerminal else {
                return nil
            }
            let newestAcceptedRevision = max(
                storage.pending?.revision ?? 0,
                storage.lastDeliveredRevision ?? 0
            )
            guard revision > newestAcceptedRevision else {
                return nil
            }
            storage.finishesAfterPendingState = finishesAfterState
            if let waiter = storage.waiter {
                storage.waiter = nil
                storage.lastDeliveredRevision = revision
                if finishesAfterState {
                    storage.isTerminal = true
                }
                return waiter
            }
            storage.pending = PendingState(
                revision: revision,
                state: state
            )
            return nil
        }
        waiter?.resume(returning: state)
    }

    package func next() async -> ContainerState? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = storage.withLock {
                    storage
                        -> ContainerState?? in
                    if let pending = storage.pending {
                        storage.pending = nil
                        storage.lastDeliveredRevision = pending.revision
                        if storage.finishesAfterPendingState {
                            storage.isTerminal = true
                        }
                        return .some(.some(pending.state))
                    }
                    if storage.isTerminal {
                        return .some(nil)
                    }
                    precondition(
                        storage.waiter == nil,
                        "A Model Container state iterator cannot call next concurrently."
                    )
                    storage.waiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: { [self] in
            cancel()
        }
    }

    package func cancel() {
        let waiter = storage.withLock { storage in
            guard !storage.isTerminal else {
                return nil as CheckedContinuation<ContainerState?, Never>?
            }
            storage.pending = nil
            storage.isTerminal = true
            let waiter = storage.waiter
            storage.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}

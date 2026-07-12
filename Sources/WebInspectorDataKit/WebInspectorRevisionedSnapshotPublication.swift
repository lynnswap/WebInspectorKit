import Synchronization

/// One revisioned publication delivered to a snapshot subscriber.
package enum WebInspectorRevisionedSnapshotUpdate<
    Snapshot: Sendable,
    Changes: Sendable
>: Sendable {
    /// The atomic state at the subscription boundary.
    case initial(revision: UInt64, snapshot: Snapshot)

    /// One contiguous change from the subscriber's current revision.
    case changes(fromRevision: UInt64, toRevision: UInt64, changes: Changes)

    /// The latest complete state after a slow subscriber lost continuity.
    case reset(revision: UInt64, snapshot: Snapshot)
}

extension WebInspectorRevisionedSnapshotUpdate: Equatable
where Snapshot: Equatable, Changes: Equatable {}

/// A single-consumer subscription to a revisioned snapshot publication.
///
/// Copies share one subscription. Creating a second iterator is a programming
/// error because two consumers cannot independently advance one capacity-one
/// mailbox.
package struct WebInspectorRevisionedSnapshotSequence<
    Snapshot: Sendable,
    Changes: Sendable,
    PublicationFailure: Error & Sendable
>: AsyncSequence, Sendable {
    package typealias Element = WebInspectorRevisionedSnapshotUpdate<Snapshot, Changes>
    package typealias Failure = PublicationFailure

    package struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        package typealias Element = WebInspectorRevisionedSnapshotUpdate<Snapshot, Changes>
        package typealias Failure = PublicationFailure

        private let subscription: WebInspectorRevisionedSnapshotSubscription<
            Snapshot,
            Changes,
            PublicationFailure
        >

        fileprivate init(
            subscription: WebInspectorRevisionedSnapshotSubscription<
                Snapshot,
                Changes,
                PublicationFailure
            >
        ) {
            self.subscription = subscription
        }

        package mutating func next() async throws(PublicationFailure) -> Element? {
            try await subscription.next()
        }

        /// Stops this subscription without affecting sibling subscribers.
        package func cancel() {
            subscription.cancel()
        }
    }

    private let subscription: WebInspectorRevisionedSnapshotSubscription<
        Snapshot,
        Changes,
        PublicationFailure
    >

    fileprivate init(
        subscription: WebInspectorRevisionedSnapshotSubscription<
            Snapshot,
            Changes,
            PublicationFailure
        >
    ) {
        self.subscription = subscription
    }

    package func makeAsyncIterator() -> AsyncIterator {
        subscription.claimIterator()
        return AsyncIterator(subscription: subscription)
    }

    /// Stops this subscription without affecting sibling subscribers.
    package func cancel() {
        subscription.cancel()
    }
}

/// Owns one current snapshot and atomically connects it to later deltas.
///
/// The publisher and each subscriber use separate synchronized owners. A
/// subscriber mailbox contains at most one semantic update. Coalescing happens
/// inside that mailbox, so a reset is never synthesized with multiple stream
/// yields.
package final class WebInspectorRevisionedSnapshotPublication<
    Snapshot: Sendable,
    Changes: Sendable,
    PublicationFailure: Error & Sendable
>: Sendable {
    package typealias Update = WebInspectorRevisionedSnapshotUpdate<Snapshot, Changes>
    package typealias UpdateSequence = WebInspectorRevisionedSnapshotSequence<
        Snapshot,
        Changes,
        PublicationFailure
    >

    private typealias Subscriber = WebInspectorRevisionedSnapshotSubscriber<
        Snapshot,
        Changes,
        PublicationFailure
    >

    private struct State {
        var revision: UInt64
        var snapshot: Snapshot
        var nextSubscriberID: UInt64 = 0
        var subscribers: [UInt64: Subscriber] = [:]
        var terminal: WebInspectorRevisionedSnapshotTerminal<PublicationFailure>?
    }

    private let state: Mutex<State>

    package init(revision: UInt64 = 0, snapshot: Snapshot) {
        state = Mutex(State(revision: revision, snapshot: snapshot))
    }

    /// The number of subscriptions that can still receive publications.
    package var activeSubscriberCount: Int {
        state.withLock { $0.subscribers.count }
    }

    var waitingSubscriberCountForTesting: Int {
        state.withLock { state in
            state.subscribers.values.count(where: \.isWaiting)
        }
    }

    /// Atomically registers a subscriber with the publisher's current state.
    package func subscribe() -> UpdateSequence {
        state.withLock { state in
            precondition(
                state.nextSubscriberID < UInt64.max,
                "Revisioned snapshot publication exhausted its subscriber identifier space."
            )
            state.nextSubscriberID += 1
            let subscriberID = state.nextSubscriberID
            let subscriber = Subscriber(
                initial: state.terminal == nil
                    ? .initial(revision: state.revision, snapshot: state.snapshot)
                    : nil,
                terminal: state.terminal
            ) { [weak self] in
                self?.removeSubscriber(subscriberID)
            }
            if state.terminal == nil {
                state.subscribers[subscriberID] = subscriber
            }
            return UpdateSequence(subscription: .init(subscriber: subscriber))
        }
    }

    /// Publishes exactly one contiguous revision and its resulting snapshot.
    package func publish(
        from fromRevision: UInt64,
        to toRevision: UInt64,
        changes: Changes,
        latestSnapshot: Snapshot
    ) {
        state.withLock { state in
            precondition(
                state.terminal == nil,
                "Cannot publish after a revisioned snapshot publication has finished."
            )
            precondition(
                fromRevision == state.revision,
                "A revisioned snapshot publication must start at its current revision."
            )
            precondition(
                fromRevision < UInt64.max && toRevision == fromRevision + 1,
                "A revisioned snapshot publication must advance by exactly one revision."
            )

            state.revision = toRevision
            state.snapshot = latestSnapshot
            let update = Update.changes(
                fromRevision: fromRevision,
                toRevision: toRevision,
                changes: changes
            )

            // Keep delivery under the publisher lock. Otherwise two concurrent
            // publish callers could update the owner in order but offer their
            // mailbox values in the opposite order after unlocking.
            for subscriber in state.subscribers.values {
                subscriber.offer(update, latestSnapshot: latestSnapshot)
            }
        }
    }

    /// Finishes every current and future subscription successfully.
    package func finish() {
        finish(with: .success)
    }

    /// Finishes every current and future subscription with a typed failure.
    package func finish(throwing failure: PublicationFailure) {
        finish(with: .failure(failure))
    }

    private func finish(
        with terminal: WebInspectorRevisionedSnapshotTerminal<PublicationFailure>
    ) {
        let subscribers = state.withLock { state -> [Subscriber] in
            guard state.terminal == nil else {
                return []
            }
            state.terminal = terminal
            let subscribers = Array(state.subscribers.values)
            state.subscribers.removeAll(keepingCapacity: false)
            return subscribers
        }
        for subscriber in subscribers {
            subscriber.finish(with: terminal)
        }
    }

    private func removeSubscriber(_ id: UInt64) {
        _ = state.withLock { state in
            state.subscribers.removeValue(forKey: id)
        }
    }

    deinit {
        finish()
    }
}

private enum WebInspectorRevisionedSnapshotTerminal<Failure: Error & Sendable>: Sendable {
    case success
    case failure(Failure)
}

private final class WebInspectorRevisionedSnapshotSubscription<
    Snapshot: Sendable,
    Changes: Sendable,
    Failure: Error & Sendable
>: Sendable {
    private let subscriber: WebInspectorRevisionedSnapshotSubscriber<Snapshot, Changes, Failure>
    private let iteratorWasClaimed = Mutex(false)

    init(
        subscriber: WebInspectorRevisionedSnapshotSubscriber<Snapshot, Changes, Failure>
    ) {
        self.subscriber = subscriber
    }

    func claimIterator() {
        let wasClaimed = iteratorWasClaimed.withLock { wasClaimed in
            defer { wasClaimed = true }
            return wasClaimed
        }
        precondition(
            wasClaimed == false,
            "A revisioned snapshot sequence supports exactly one iterator."
        )
    }

    func next() async throws(Failure) -> WebInspectorRevisionedSnapshotUpdate<Snapshot, Changes>? {
        try await subscriber.next()
    }

    func cancel() {
        subscriber.cancel()
    }

    deinit {
        subscriber.cancel()
    }
}

private final class WebInspectorRevisionedSnapshotSubscriber<
    Snapshot: Sendable,
    Changes: Sendable,
    Failure: Error & Sendable
>: Sendable {
    typealias Update = WebInspectorRevisionedSnapshotUpdate<Snapshot, Changes>

    private enum Delivery: Sendable {
        case update(Update)
        case finished
        case failed(Failure)
    }

    private struct State {
        var pending: Update?
        var waiter: CheckedContinuation<Delivery, Never>?
        var terminal: WebInspectorRevisionedSnapshotTerminal<Failure>?
        var terminalWasDelivered = false
        var terminationWasNotified = false
        var nextIsInProgress = false
    }

    private struct Completion {
        var waiter: CheckedContinuation<Delivery, Never>?
        var delivery: Delivery?
        var shouldNotifyTermination: Bool
    }

    private let state: Mutex<State>
    private let onTermination: @Sendable () -> Void

    init(
        initial: Update?,
        terminal: WebInspectorRevisionedSnapshotTerminal<Failure>?,
        onTermination: @escaping @Sendable () -> Void
    ) {
        state = Mutex(State(pending: initial, terminal: terminal))
        self.onTermination = onTermination
    }

    var isWaiting: Bool {
        state.withLock { $0.waiter != nil }
    }

    func offer(_ update: Update, latestSnapshot: Snapshot) {
        let waiter = state.withLock { state -> CheckedContinuation<Delivery, Never>? in
            guard state.terminal == nil else {
                return nil
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            switch state.pending {
            case nil:
                state.pending = update
            case .initial:
                state.pending = .initial(
                    revision: update.toRevision,
                    snapshot: latestSnapshot
                )
            case .changes, .reset:
                state.pending = .reset(
                    revision: update.toRevision,
                    snapshot: latestSnapshot
                )
            }
            return nil
        }
        waiter?.resume(returning: .update(update))
    }

    func finish(with terminal: WebInspectorRevisionedSnapshotTerminal<Failure>) {
        let completion = state.withLock { state -> Completion? in
            guard state.terminal == nil else {
                return nil
            }
            state.terminal = terminal
            let delivery = state.waiter.map { _ in
                state.terminalWasDelivered = true
                return Self.delivery(for: terminal)
            }
            let waiter = state.waiter
            state.waiter = nil
            let shouldNotify = Self.markTerminationNotified(&state)
            return Completion(
                waiter: waiter,
                delivery: delivery,
                shouldNotifyTermination: shouldNotify
            )
        }
        complete(completion)
    }

    func cancel() {
        let completion = state.withLock { state -> Completion? in
            guard state.terminalWasDelivered == false
                    || state.pending != nil
                    || state.waiter != nil else {
                return nil
            }
            state.pending = nil
            state.terminal = .success
            state.terminalWasDelivered = true
            let waiter = state.waiter
            state.waiter = nil
            let shouldNotify = Self.markTerminationNotified(&state)
            return Completion(
                waiter: waiter,
                delivery: waiter == nil ? nil : .finished,
                shouldNotifyTermination: shouldNotify
            )
        }
        complete(completion)
    }

    func next() async throws(Failure) -> Update? {
        if Task.isCancelled {
            cancel()
            return nil
        }

        let mayStart = state.withLock { state in
            guard state.nextIsInProgress == false else {
                return false
            }
            state.nextIsInProgress = true
            return true
        }
        precondition(
            mayStart,
            "A revisioned snapshot iterator does not support concurrent next() calls."
        )
        defer {
            state.withLock { $0.nextIsInProgress = false }
        }

        let delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Delivery? in
                    if let pending = state.pending {
                        state.pending = nil
                        return .update(pending)
                    }
                    if let terminal = state.terminal {
                        guard state.terminalWasDelivered == false else {
                            return .finished
                        }
                        state.terminalWasDelivered = true
                        return Self.delivery(for: terminal)
                    }
                    precondition(
                        state.waiter == nil,
                        "A revisioned snapshot subscriber supports one waiter."
                    )
                    state.waiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: { [self] in
            cancel()
        }

        switch delivery {
        case let .update(update):
            return update
        case .finished:
            return nil
        case let .failed(failure):
            throw failure
        }
    }

    private func complete(_ completion: Completion?) {
        guard let completion else {
            return
        }
        if completion.shouldNotifyTermination {
            onTermination()
        }
        if let waiter = completion.waiter, let delivery = completion.delivery {
            waiter.resume(returning: delivery)
        }
    }

    private static func delivery(
        for terminal: WebInspectorRevisionedSnapshotTerminal<Failure>
    ) -> Delivery {
        switch terminal {
        case .success:
            return .finished
        case let .failure(failure):
            return .failed(failure)
        }
    }

    private static func markTerminationNotified(_ state: inout State) -> Bool {
        guard state.terminationWasNotified == false else {
            return false
        }
        state.terminationWasNotified = true
        return true
    }
}

private extension WebInspectorRevisionedSnapshotUpdate {
    var toRevision: UInt64 {
        switch self {
        case let .initial(revision, _), let .reset(revision, _):
            return revision
        case let .changes(_, toRevision, _):
            return toRevision
        }
    }
}

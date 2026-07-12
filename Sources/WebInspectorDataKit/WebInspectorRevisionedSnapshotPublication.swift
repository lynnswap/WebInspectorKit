import Synchronization

/// Describes whether an owner-supplied rebase establishes initial state or
/// replaces state whose change continuity was lost.
package enum WebInspectorRevisionedSnapshotRebaseDisposition: Equatable, Sendable {
    case initial
    case reset
}

/// The owner snapshot captured while rebasing one slow subscriber.
package struct WebInspectorRevisionedSnapshotRebase<Snapshot: Sendable>: Sendable {
    package let disposition: WebInspectorRevisionedSnapshotRebaseDisposition
    package let revision: UInt64
    package let snapshot: Snapshot
}

extension WebInspectorRevisionedSnapshotRebase: Equatable where Snapshot: Equatable {}

/// A rejected attempt to rebase one slow subscriber.
package enum WebInspectorRevisionedSnapshotRebaseError: Error, Equatable, Sendable {
    case foreignPublication
    case publicationTerminated
    case staleSnapshot(expectedRevision: UInt64, suppliedRevision: UInt64)
    case staleToken
    case subscriptionCancelled
}

/// An opaque request proving that one subscriber consumed a reset marker.
package struct WebInspectorRevisionedSnapshotRebaseToken: Equatable, Sendable {
    fileprivate let publicationIdentity: WebInspectorRevisionedSnapshotPublicationIdentity
    fileprivate let subscriberID: UInt64
    fileprivate let generation: UInt64

    package static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.publicationIdentity === rhs.publicationIdentity
            && lhs.subscriberID == rhs.subscriberID
            && lhs.generation == rhs.generation
    }
}

/// One revisioned publication delivered to a snapshot subscriber.
package enum WebInspectorRevisionedSnapshotUpdate<
    Snapshot: Sendable,
    Changes: Sendable
>: Sendable {
    /// The atomic state at the subscription boundary.
    case initial(revision: UInt64, snapshot: Snapshot)

    /// One contiguous change from the subscriber's current revision.
    case changes(fromRevision: UInt64, toRevision: UInt64, changes: Changes)

    /// A slow subscriber must ask the state owner for one current snapshot.
    case resetRequired(
        latestRevision: UInt64,
        token: WebInspectorRevisionedSnapshotRebaseToken
    )
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

        private let subscription:
            WebInspectorRevisionedSnapshotSubscription<
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

    private let subscription:
        WebInspectorRevisionedSnapshotSubscription<
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

    package func owns(
        _ token: WebInspectorRevisionedSnapshotRebaseToken
    ) -> Bool {
        subscription.owns(token)
    }
}

/// Owns one revision and atomically connects owner snapshots to later deltas.
///
/// The publisher and each subscriber use separate synchronized owners. A
/// subscriber mailbox contains at most one semantic update. Coalescing happens
/// inside that mailbox. The publication never stores a full current snapshot;
/// the state owner supplies one at subscription and only after a slow consumer
/// actually dequeues a reset marker.
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
    package typealias RebaseToken = WebInspectorRevisionedSnapshotRebaseToken
    package typealias Rebase = WebInspectorRevisionedSnapshotRebase<Snapshot>

    private typealias Subscriber = WebInspectorRevisionedSnapshotSubscriber<
        Snapshot,
        Changes,
        PublicationFailure
    >

    private struct State {
        var revision: UInt64
        var nextSubscriberID: UInt64 = 0
        var subscribers: [UInt64: Subscriber] = [:]
        var terminal: WebInspectorRevisionedSnapshotTerminal<PublicationFailure>?
    }

    private let identity = WebInspectorRevisionedSnapshotPublicationIdentity()
    private let state: Mutex<State>

    package init(revision: UInt64 = 0) {
        state = Mutex(State(revision: revision))
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

    var currentRevisionForTesting: UInt64 {
        state.withLock { $0.revision }
    }

    /// Registers one owner-supplied snapshot at the publisher's current revision.
    ///
    /// The semantic owner must capture `snapshot` and call this method in the
    /// same actor turn so no owner mutation can fall between the snapshot and
    /// subscriber registration.
    package func subscribe(
        revision: UInt64,
        snapshot: Snapshot
    ) -> UpdateSequence {
        state.withLock { state in
            precondition(
                revision == state.revision,
                "A revisioned snapshot subscription must use the publication's current revision."
            )
            precondition(
                state.nextSubscriberID < UInt64.max,
                "Revisioned snapshot publication exhausted its subscriber identifier space."
            )
            state.nextSubscriberID += 1
            let subscriberID = state.nextSubscriberID
            let subscriber = Subscriber(
                initial: state.terminal == nil
                    ? .initial(revision: revision, snapshot: snapshot)
                    : nil,
                subscriberID: subscriberID,
                baseRevision: revision,
                publicationIdentity: identity,
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

    /// Publishes exactly one contiguous revision without constructing a snapshot.
    package func publish(
        from fromRevision: UInt64,
        to toRevision: UInt64,
        changes: Changes
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

            // Keep delivery under the publisher lock. Otherwise two concurrent
            // publish callers could update the owner in order but offer their
            // mailbox values in the opposite order after unlocking.
            for subscriber in state.subscribers.values {
                subscriber.offer(
                    from: fromRevision,
                    to: toRevision,
                    changes: changes
                )
            }
        }
    }

    /// Commits an owner snapshot directly to the slow consumer that requested it.
    ///
    /// The semantic owner must call this method in the same actor turn in which
    /// it owns `snapshot`. The autoclosure is evaluated only after the token is
    /// atomically consumed, so rejected rebase attempts cannot construct an
    /// owner snapshot. The result is returned directly and is never retained by
    /// the publication or enqueued in the subscriber mailbox.
    package func rebase(
        _ token: RebaseToken,
        revision: UInt64,
        snapshot: @autoclosure () -> Snapshot
    ) throws(WebInspectorRevisionedSnapshotRebaseError) -> Rebase {
        guard token.publicationIdentity === identity else {
            throw WebInspectorRevisionedSnapshotRebaseError.foreignPublication
        }

        let result:
            Result<
                WebInspectorRevisionedSnapshotRebaseDisposition,
                WebInspectorRevisionedSnapshotRebaseError
            > = state.withLock { state in
                guard state.terminal == nil else {
                    return .failure(.publicationTerminated)
                }
                guard let subscriber = state.subscribers[token.subscriberID] else {
                    return .failure(.subscriptionCancelled)
                }
                guard revision == state.revision else {
                    return .failure(
                        .staleSnapshot(
                            expectedRevision: state.revision,
                            suppliedRevision: revision
                        ))
                }
                return subscriber.rebase(
                    generation: token.generation,
                    revision: revision
                )
            }
        let disposition = try result.get()
        return Rebase(
            disposition: disposition,
            revision: revision,
            snapshot: snapshot()
        )
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
        let completions = state.withLock { state -> [@Sendable () -> Void] in
            guard state.terminal == nil else {
                return []
            }
            state.terminal = terminal
            let completions = state.subscribers.values.map { subscriber in
                subscriber.prepareToFinish(with: terminal)
            }
            state.subscribers.removeAll(keepingCapacity: false)
            return completions
        }
        for complete in completions {
            complete()
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

fileprivate final class WebInspectorRevisionedSnapshotPublicationIdentity: Sendable {}

fileprivate enum WebInspectorRevisionedSnapshotTerminal<Failure: Error & Sendable>: Sendable {
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

    func next() async throws(Failure) -> WebInspectorRevisionedSnapshotUpdate<
        Snapshot,
        Changes
    >? {
        try await subscriber.next()
    }

    func cancel() {
        subscriber.cancel()
    }

    func owns(_ token: WebInspectorRevisionedSnapshotRebaseToken) -> Bool {
        subscriber.owns(token)
    }

    deinit {
        subscriber.cancel()
    }
}

fileprivate final class WebInspectorRevisionedSnapshotSubscriber<
    Snapshot: Sendable,
    Changes: Sendable,
    Failure: Error & Sendable
>: Sendable {
    typealias Update = WebInspectorRevisionedSnapshotUpdate<Snapshot, Changes>
    typealias RebaseToken = WebInspectorRevisionedSnapshotRebaseToken

    private enum Pending: Sendable {
        case initial(revision: UInt64, snapshot: Snapshot)
        case changes(fromRevision: UInt64, toRevision: UInt64, changes: Changes)
        case resetRequired(
            latestRevision: UInt64,
            generation: UInt64,
            disposition: WebInspectorRevisionedSnapshotRebaseDisposition
        )
    }

    private struct OutstandingRebase: Sendable {
        var latestRevision: UInt64
        let generation: UInt64
        let disposition: WebInspectorRevisionedSnapshotRebaseDisposition
    }

    private enum Delivery: Sendable {
        case update(Update)
        case finished
        case failed(Failure)
    }

    private struct State {
        var baseRevision: UInt64
        var hasDeliveredInitial = false
        var nextRebaseGeneration: UInt64 = 0
        var pending: Pending?
        var outstandingRebase: OutstandingRebase?
        var waiter: CheckedContinuation<Delivery, Never>?
        var terminal: WebInspectorRevisionedSnapshotTerminal<Failure>?
        var wasCancelled = false
        var terminalWasDelivered = false
        var terminationWasNotified = false
        var nextIsInProgress = false
    }

    private struct OfferedDelivery {
        let waiter: CheckedContinuation<Delivery, Never>
        let update: Update
    }

    private struct Completion: Sendable {
        var waiter: CheckedContinuation<Delivery, Never>?
        var delivery: Delivery?
        var shouldNotifyTermination: Bool
    }

    private let subscriberID: UInt64
    private let publicationIdentity: WebInspectorRevisionedSnapshotPublicationIdentity
    private let state: Mutex<State>
    private let onTermination: @Sendable () -> Void

    init(
        initial: Update?,
        subscriberID: UInt64,
        baseRevision: UInt64,
        publicationIdentity: WebInspectorRevisionedSnapshotPublicationIdentity,
        terminal: WebInspectorRevisionedSnapshotTerminal<Failure>?,
        onTermination: @escaping @Sendable () -> Void
    ) {
        let pending = initial.map { update -> Pending in
            switch update {
            case let .initial(revision, snapshot):
                return .initial(revision: revision, snapshot: snapshot)
            case .changes, .resetRequired:
                preconditionFailure("A new revisioned snapshot subscriber must start with initial state.")
            }
        }
        state = Mutex(
            State(
                baseRevision: baseRevision,
                pending: pending,
                terminal: terminal
            ))
        self.subscriberID = subscriberID
        self.publicationIdentity = publicationIdentity
        self.onTermination = onTermination
    }

    var isWaiting: Bool {
        state.withLock { $0.waiter != nil }
    }

    func owns(_ token: RebaseToken) -> Bool {
        token.publicationIdentity === publicationIdentity
            && token.subscriberID == subscriberID
    }

    func offer(
        from fromRevision: UInt64,
        to toRevision: UInt64,
        changes: Changes
    ) {
        let delivery = state.withLock { state -> OfferedDelivery? in
            guard state.terminal == nil, state.wasCancelled == false else {
                return nil
            }

            if var outstandingRebase = state.outstandingRebase {
                precondition(
                    outstandingRebase.latestRevision == fromRevision,
                    "A pending rebase marker must advance contiguously."
                )
                outstandingRebase.latestRevision = toRevision
                state.outstandingRebase = outstandingRebase
                return nil
            }

            if let waiter = state.waiter {
                precondition(
                    state.pending == nil,
                    "A waiting revisioned snapshot subscriber cannot also have a pending update."
                )
                precondition(
                    state.hasDeliveredInitial && state.baseRevision == fromRevision,
                    "A waiting revisioned snapshot subscriber must receive a contiguous change."
                )
                state.waiter = nil
                state.baseRevision = toRevision
                return OfferedDelivery(
                    waiter: waiter,
                    update: .changes(
                        fromRevision: fromRevision,
                        toRevision: toRevision,
                        changes: changes
                    )
                )
            }

            switch state.pending {
            case nil:
                precondition(
                    state.hasDeliveredInitial && state.baseRevision == fromRevision,
                    "A revisioned snapshot subscriber must queue a contiguous change."
                )
                state.pending = .changes(
                    fromRevision: fromRevision,
                    toRevision: toRevision,
                    changes: changes
                )

            case let .initial(revision, _):
                precondition(
                    revision == fromRevision,
                    "An unconsumed initial snapshot must match the next publication."
                )
                state.pending = .resetRequired(
                    latestRevision: toRevision,
                    generation: Self.nextRebaseGeneration(&state),
                    disposition: .initial
                )

            case let .changes(_, pendingToRevision, _):
                precondition(
                    pendingToRevision == fromRevision,
                    "A pending change must match the next publication."
                )
                state.pending = .resetRequired(
                    latestRevision: toRevision,
                    generation: Self.nextRebaseGeneration(&state),
                    disposition: .reset
                )

            case let .resetRequired(latestRevision, generation, disposition):
                precondition(
                    latestRevision == fromRevision,
                    "A reset marker must match the next publication."
                )
                state.pending = .resetRequired(
                    latestRevision: toRevision,
                    generation: generation,
                    disposition: disposition
                )
            }
            return nil
        }
        if let delivery {
            delivery.waiter.resume(returning: .update(delivery.update))
        }
    }

    func rebase(
        generation: UInt64,
        revision: UInt64
    ) -> Result<
        WebInspectorRevisionedSnapshotRebaseDisposition,
        WebInspectorRevisionedSnapshotRebaseError
    > {
        state.withLock { state in
            guard state.wasCancelled == false else {
                return .failure(.subscriptionCancelled)
            }
            guard let outstandingRebase = state.outstandingRebase,
                outstandingRebase.generation == generation
            else {
                return .failure(.staleToken)
            }
            guard outstandingRebase.latestRevision == revision else {
                return .failure(
                    .staleSnapshot(
                        expectedRevision: outstandingRebase.latestRevision,
                        suppliedRevision: revision
                    ))
            }
            state.outstandingRebase = nil
            state.baseRevision = revision
            state.hasDeliveredInitial = true
            return .success(outstandingRebase.disposition)
        }
    }

    func prepareToFinish(
        with terminal: WebInspectorRevisionedSnapshotTerminal<Failure>
    ) -> @Sendable () -> Void {
        let completion = state.withLock { state -> Completion? in
            guard state.terminal == nil else {
                return nil
            }
            if case .resetRequired = state.pending {
                state.pending = nil
            }
            state.outstandingRebase = nil
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
        return { [self] in
            complete(completion)
        }
    }

    func cancel() {
        let completion = state.withLock { state -> Completion? in
            guard state.wasCancelled == false else {
                return nil
            }
            guard
                state.terminalWasDelivered == false
                    || state.pending != nil
                    || state.outstandingRebase != nil
                    || state.waiter != nil
            else {
                return nil
            }
            state.wasCancelled = true
            state.pending = nil
            state.outstandingRebase = nil
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
                        return dequeue(pending, state: &state)
                    }
                    precondition(
                        state.outstandingRebase == nil,
                        "A reset marker must be rebased before requesting the next update."
                    )
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

    private func dequeue(
        _ pending: Pending,
        state: inout State
    ) -> Delivery {
        switch pending {
        case let .initial(revision, snapshot):
            precondition(
                state.hasDeliveredInitial == false && state.baseRevision == revision,
                "Initial state must establish the subscriber's first revision."
            )
            state.hasDeliveredInitial = true
            return .update(.initial(revision: revision, snapshot: snapshot))

        case let .changes(fromRevision, toRevision, changes):
            precondition(
                state.hasDeliveredInitial && state.baseRevision == fromRevision,
                "A dequeued revisioned change must be contiguous."
            )
            state.baseRevision = toRevision
            return .update(
                .changes(
                    fromRevision: fromRevision,
                    toRevision: toRevision,
                    changes: changes
                ))

        case let .resetRequired(latestRevision, generation, disposition):
            precondition(
                state.outstandingRebase == nil,
                "A revisioned snapshot subscriber supports one outstanding rebase."
            )
            state.outstandingRebase = OutstandingRebase(
                latestRevision: latestRevision,
                generation: generation,
                disposition: disposition
            )
            let token = RebaseToken(
                publicationIdentity: publicationIdentity,
                subscriberID: subscriberID,
                generation: generation
            )
            return .update(
                .resetRequired(
                    latestRevision: latestRevision,
                    token: token
                ))
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

    private static func nextRebaseGeneration(_ state: inout State) -> UInt64 {
        precondition(
            state.nextRebaseGeneration < UInt64.max,
            "A revisioned snapshot subscriber exhausted its rebase generation space."
        )
        state.nextRebaseGeneration += 1
        return state.nextRebaseGeneration
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

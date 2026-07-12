import Synchronization
import WebInspectorProxyKit

package struct WebInspectorModelContextRegistrationID: Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum WebInspectorModelContainerCoreError: Error, Equatable, Sendable {
    case closed
    case canonicalStore(WebInspectorCanonicalModelStoreError)
    case contextRegistrationNotFound(WebInspectorModelContextRegistrationID)
    case acknowledgementRevisionAhead(current: UInt64, proposed: UInt64)
    case acknowledgementRevisionMovedBackward(
        registrationID: WebInspectorModelContextRegistrationID,
        previous: UInt64,
        proposed: UInt64
    )
    case rebaseTokenMismatch(WebInspectorModelContextRegistrationID)
    case rebase(WebInspectorRevisionedSnapshotRebaseError)
    case foreignAcknowledgementBarrier
    case contextNotActivated(WebInspectorModelContextRegistrationID)
    case detachInProgress
    case detachTransactionMismatch
    case closeTransactionMismatch
}

package typealias WebInspectorCanonicalModelUpdateSequence =
    WebInspectorRevisionedSnapshotSequence<
        WebInspectorCanonicalModelSnapshot,
        WebInspectorCanonicalModelTransaction,
        Never
    >

package enum WebInspectorModelContextMaterializationClaim: Equatable, Sendable {
    case admitted
    case closed
}

package struct WebInspectorModelContextRegistration: Sendable {
    package let id: WebInspectorModelContextRegistrationID
    package let updates: WebInspectorCanonicalModelUpdateSequence
    fileprivate let admission: WebInspectorModelContextAdmissionGate

    /// Linearizes wrapper/driver ownership against terminal Container close.
    /// The caller must already own cancellation-safe cleanup before claiming;
    /// an admitted claim becomes a lifecycle acknowledgement obligation.
    package func claimForMaterialization()
        -> WebInspectorModelContextMaterializationClaim
    {
        admission.claim()
    }
}

/// The stable subscription installed synchronously with the Container Core.
/// Materializing the public main context later activates this same identity;
/// it never creates a replacement registration.
package struct WebInspectorModelContextSeed: Sendable {
    package let id: WebInspectorModelContextRegistrationID
    package let updates: WebInspectorCanonicalModelUpdateSequence
    fileprivate let admission: WebInspectorModelContextAdmissionGate

    /// Linearizes the synchronous main-context getter against terminal close.
    /// The wrapper must already own cancellation-safe cleanup before claiming;
    /// an admitted claim becomes a lifecycle acknowledgement obligation.
    package func claimForMaterialization()
        -> WebInspectorModelContextMaterializationClaim
    {
        admission.claim()
    }
}

package struct WebInspectorCanonicalModelCommit: Equatable, Sendable {
    package let fromRevision: UInt64
    package let toRevision: UInt64
    package let transaction: WebInspectorCanonicalModelTransaction
}

package struct WebInspectorModelContextAcknowledgementBarrier: Equatable, Sendable {
    fileprivate let coreIdentity: WebInspectorModelContainerCoreIdentity
    fileprivate let id: UInt64
    fileprivate let waiter: WebInspectorModelContextAcknowledgementWaiter
    package let revision: UInt64

    package static func == (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.coreIdentity === rhs.coreIdentity
            && lhs.id == rhs.id
            && lhs.revision == rhs.revision
    }
}

package struct WebInspectorModelContainerReset: Equatable, Sendable {
    package let commit: WebInspectorCanonicalModelCommit
    package let acknowledgementBarrier: WebInspectorModelContextAcknowledgementBarrier
}

package struct WebInspectorModelContainerClose: Equatable, Sendable {
    package let acknowledgementBarrier: WebInspectorModelContextAcknowledgementBarrier
}

package struct WebInspectorModelContainerCorePerformanceCounters: Equatable, Sendable {
    package fileprivate(set) var publishedTransactionCount = 0
    package fileprivate(set) var ignoredEmptyTransactionCount = 0
    package fileprivate(set) var contextRegistrationCount = 0
    package fileprivate(set) var contextUnregistrationCount = 0
}

package struct WebInspectorModelContainerCoreMetrics: Equatable, Sendable {
    package let revision: UInt64
    package let activeContextRegistrationCount: Int
    package let core: WebInspectorModelContainerCorePerformanceCounters
    package let canonicalStore: WebInspectorCanonicalModelStorePerformanceCounters
}

/// The single ordered owner of canonical inspection state and context
/// publication.
///
/// This actor contains no native attachment, UI, Observable model, query, or
/// domain-specific reduction. Feed semantics remain in the pure canonical
/// store and subscriber coalescing remains in the synchronized publication.
package actor WebInspectorModelContainerCore {
    package typealias Publication = WebInspectorRevisionedSnapshotPublication<
        WebInspectorCanonicalModelSnapshot,
        WebInspectorCanonicalModelTransaction,
        Never
    >

    private enum Lifecycle: Sendable {
        case open
        case detaching
        case closing
        case closed
    }

    private enum ContextRegistrationPhase: Equatable, Sendable {
        case reserved
        case active
        case closing

        var isMaterialized: Bool {
            self != .reserved
        }
    }

    private struct ContextRegistrationState {
        let updates: WebInspectorCanonicalModelUpdateSequence
        let admission: WebInspectorModelContextAdmissionGate
        var phase: ContextRegistrationPhase
        var acknowledgedRevision: UInt64?
    }

    private enum AcknowledgementRequirement: Sendable {
        case revision(UInt64)
        case close
    }

    private struct AcknowledgementBarrierState {
        let requirement: AcknowledgementRequirement
        var remainingRegistrationIDs: Set<WebInspectorModelContextRegistrationID>
        let waiter: WebInspectorModelContextAcknowledgementWaiter
    }

    package nonisolated let storeID: WebInspectorContainerStoreID
    package nonisolated let configuredDomains: Set<ModelDomain>
    package nonisolated let mainContextSeed: WebInspectorModelContextSeed

    private nonisolated let publication: Publication
    private nonisolated let identity = WebInspectorModelContainerCoreIdentity()
    private var canonicalStore: WebInspectorCanonicalModelStore
    private var revision: UInt64 = 0
    private var lifecycle = Lifecycle.open
    private var nextContextRegistrationID: UInt64 = 0
    private var contextRegistrations: [WebInspectorModelContextRegistrationID: ContextRegistrationState] = [:]
    private var nextAcknowledgementBarrierID: UInt64 = 0
    private var acknowledgementBarriers: [UInt64: AcknowledgementBarrierState] = [:]
    private var detachTransaction: WebInspectorModelContainerReset?
    private var completedDetachTransaction: WebInspectorModelContainerReset?
    private var closeTransaction: WebInspectorModelContainerClose?
    private var performanceCounters =
        WebInspectorModelContainerCorePerformanceCounters()

    package init(
        storeID: WebInspectorContainerStoreID = WebInspectorContainerStoreID(),
        configuredDomains: Set<ModelDomain>
    ) {
        var canonicalStore = WebInspectorCanonicalModelStore(
            storeID: storeID,
            configuredDomains: configuredDomains
        )
        let publication = Publication()
        let mainContextID = WebInspectorModelContextRegistrationID(
            rawValue: 1
        )
        let mainContextAdmission = WebInspectorModelContextAdmissionGate()
        let mainContextUpdates = publication.subscribe(
            revision: 0,
            snapshot: canonicalStore.snapshot(reason: .initial)
        )

        self.storeID = storeID
        self.canonicalStore = canonicalStore
        self.configuredDomains = canonicalStore.configuredDomains
        self.publication = publication
        mainContextSeed = WebInspectorModelContextSeed(
            id: mainContextID,
            updates: mainContextUpdates,
            admission: mainContextAdmission
        )
        nextContextRegistrationID = mainContextID.rawValue
        contextRegistrations[mainContextID] = ContextRegistrationState(
            updates: mainContextUpdates,
            admission: mainContextAdmission,
            phase: .reserved,
            acknowledgedRevision: nil
        )
        performanceCounters.contextRegistrationCount = 1
    }

    package var currentRevision: UInt64 {
        revision
    }

    package var isClosed: Bool {
        lifecycle == .closed
    }

    package var metrics: WebInspectorModelContainerCoreMetrics {
        WebInspectorModelContainerCoreMetrics(
            revision: revision,
            activeContextRegistrationCount: contextRegistrations.values.count {
                $0.phase.isMaterialized || $0.admission.wasClaimed
            },
            core: performanceCounters,
            canonicalStore: canonicalStore.performanceCounters
        )
    }

    package func acknowledgedRevision(
        for registrationID: WebInspectorModelContextRegistrationID
    ) -> UInt64? {
        contextRegistrations[registrationID]?.acknowledgedRevision
    }

    /// Atomically captures current canonical state and reserves its first
    /// subsequent revision. The factory must claim or abandon the reservation.
    package func registerContext()
        throws(WebInspectorModelContainerCoreError)
        -> WebInspectorModelContextRegistration
    {
        guard lifecycle == .open || lifecycle == .detaching else {
            throw .closed
        }
        precondition(
            nextContextRegistrationID < UInt64.max,
            "Model Container Core exhausted context registration identifiers."
        )
        nextContextRegistrationID += 1
        let registrationID = WebInspectorModelContextRegistrationID(
            rawValue: nextContextRegistrationID
        )
        let snapshot = canonicalStore.snapshot(reason: .initial)
        let admission = WebInspectorModelContextAdmissionGate()
        let updates = publication.subscribe(
            revision: revision,
            snapshot: snapshot
        )
        contextRegistrations[registrationID] = ContextRegistrationState(
            updates: updates,
            admission: admission,
            phase: .reserved,
            acknowledgedRevision: nil
        )
        performanceCounters.contextRegistrationCount += 1
        return WebInspectorModelContextRegistration(
            id: registrationID,
            updates: updates,
            admission: admission
        )
    }

    /// Commits a synchronously claimed main or custom reservation before its
    /// driver starts applying owner state. Activation is idempotent.
    package func activateContext(
        _ registrationID: WebInspectorModelContextRegistrationID
    ) throws(WebInspectorModelContainerCoreError) {
        guard var registration = contextRegistrations[registrationID] else {
            throw .contextRegistrationNotFound(registrationID)
        }
        guard registration.admission.wasClaimed else {
            if registration.admission.isClosed {
                throw .closed
            }
            throw .contextNotActivated(registrationID)
        }

        switch lifecycle {
        case .open, .detaching:
            switch registration.phase {
            case .reserved:
                registration.phase = .active
                registration.acknowledgedRevision = nil
                contextRegistrations[registrationID] = registration
            case .active:
                return
            case .closing:
                throw .closed
            }
        case .closing:
            guard registration.phase == .closing else {
                throw .closed
            }
        case .closed:
            throw .closed
        }
    }

    /// Removes one context without changing sibling subscriptions.
    @discardableResult
    package func unregisterContext(
        _ registrationID: WebInspectorModelContextRegistrationID
    ) -> Bool {
        guard
            var registration = contextRegistrations[registrationID]
        else {
            return false
        }
        if registration.phase == .reserved,
            registration.admission.wasClaimed
        {
            registration.phase =
                lifecycle == .open || lifecycle == .detaching
                ? .active
                : .closing
        }
        precondition(
            registration.phase != .reserved,
            "An unmaterialized context reservation must be abandoned, not unregistered."
        )
        precondition(
            registration.admission.close(),
            "A materialized context must retain its admission until unregister."
        )
        contextRegistrations[registrationID] = nil
        registration.updates.cancel()
        performanceCounters.contextUnregistrationCount += 1
        resumeSatisfiedBarriers(
            afterRemoving: registrationID
        )
        return true
    }

    /// Releases a custom construction reservation whose wrapper never claimed
    /// driver ownership. The stable main-context seed is owned until Container
    /// close and cannot be abandoned.
    @discardableResult
    package func abandonContext(
        _ registrationID: WebInspectorModelContextRegistrationID
    ) -> Bool {
        guard registrationID != mainContextSeed.id,
            let registration = contextRegistrations[registrationID],
            registration.phase == .reserved,
            registration.admission.abandon()
        else {
            return false
        }
        contextRegistrations[registrationID] = nil
        registration.updates.cancel()
        performanceCounters.contextUnregistrationCount += 1
        return true
    }

    /// Starts one independent context close. Its supervisor must unregister
    /// only after the driver and every owner/FRC completion have finished.
    @discardableResult
    package func beginContextClose(
        _ registrationID: WebInspectorModelContextRegistrationID
    ) throws(WebInspectorModelContainerCoreError) -> Bool {
        guard lifecycle != .closed else {
            throw .closed
        }
        guard var registration = contextRegistrations[registrationID] else {
            return false
        }
        if registration.phase == .reserved {
            guard registration.admission.wasClaimed else {
                throw .contextNotActivated(registrationID)
            }
            registration.phase = .active
            registration.acknowledgedRevision = nil
        }
        precondition(
            registration.admission.close(),
            "A materialized context must retain its admission through close."
        )
        guard registration.phase != .closing else {
            return true
        }
        registration.phase = .closing
        contextRegistrations[registrationID] = registration
        registration.updates.cancel()
        return true
    }

    /// Records that one context has atomically applied state through a
    /// canonical revision. This is the detach/attach lifecycle barrier seam.
    package func acknowledgeContext(
        _ registrationID: WebInspectorModelContextRegistrationID,
        through proposedRevision: UInt64
    ) throws(WebInspectorModelContainerCoreError) {
        guard lifecycle != .closed else {
            throw .closed
        }
        guard var registration = contextRegistrations[registrationID] else {
            throw .contextRegistrationNotFound(registrationID)
        }
        guard registration.phase != .reserved else {
            throw .contextNotActivated(registrationID)
        }
        guard proposedRevision <= revision else {
            throw .acknowledgementRevisionAhead(
                current: revision,
                proposed: proposedRevision
            )
        }
        if let previous = registration.acknowledgedRevision {
            guard proposedRevision >= previous else {
                throw .acknowledgementRevisionMovedBackward(
                    registrationID: registrationID,
                    previous: previous,
                    proposed: proposedRevision
                )
            }
        }
        registration.acknowledgedRevision = proposedRevision
        contextRegistrations[registrationID] = registration
        resumeSatisfiedBarriers(
            afterAcknowledging: registrationID,
            through: proposedRevision
        )
    }

    /// Captures a current owner-atomic snapshot only after this context
    /// consumed its capacity-one reset marker.
    package func rebaseContext(
        _ token: Publication.RebaseToken,
        for registrationID: WebInspectorModelContextRegistrationID
    ) throws(WebInspectorModelContainerCoreError) -> Publication.Rebase {
        guard lifecycle == .open || lifecycle == .detaching else {
            throw .closed
        }
        guard let registration = contextRegistrations[registrationID] else {
            throw .contextRegistrationNotFound(registrationID)
        }
        guard registration.phase != .reserved else {
            throw .contextNotActivated(registrationID)
        }
        guard registration.updates.owns(token) else {
            throw .rebaseTokenMismatch(registrationID)
        }
        do {
            return try publication.rebase(
                token,
                revision: revision,
                snapshot: canonicalStore.snapshot(reason: .onDemandRebase)
            )
        } catch {
            throw .rebase(error)
        }
    }

    /// Reduces and publishes one ordered feed record. Empty transactions do
    /// not advance the canonical revision or touch subscriber mailboxes.
    @discardableResult
    package func reduce(
        _ record: ConnectionModelFeedRecord,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration
    ) throws(WebInspectorModelContainerCoreError) -> WebInspectorCanonicalModelCommit? {
        guard lifecycle == .open else {
            if lifecycle == .detaching {
                throw .detachInProgress
            }
            throw .closed
        }
        let transaction: WebInspectorCanonicalModelTransaction
        do {
            transaction = try canonicalStore.reduce(
                record,
                attachmentGeneration: attachmentGeneration
            )
        } catch let error as WebInspectorCanonicalModelStoreError {
            throw .canonicalStore(error)
        } catch {
            preconditionFailure(
                "Canonical Model Store escaped its declared error contract: \(error)"
            )
        }
        return publish(transaction)
    }

    /// Clears canonical membership and publishes a nonterminal reset. Every
    /// materialized context at this boundary must apply or unregister from it.
    /// Unclaimed reservations have no owner graph, are acknowledged internally,
    /// and later start from their coalesced reset/rebase state.
    @discardableResult
    package func resetForDetach()
        throws(WebInspectorModelContainerCoreError)
        -> WebInspectorModelContainerReset?
    {
        if lifecycle == .detaching {
            return detachTransaction
        }
        guard lifecycle == .open else {
            throw .closed
        }
        let transaction = canonicalStore.clearForDetach()
        guard let commit = publish(transaction) else {
            return nil
        }
        precondition(
            transaction.resetSnapshot != nil,
            "A canonical detach transaction must carry one empty reset snapshot."
        )
        let barrier = makeRevisionAcknowledgementBarrier(
            through: commit.toRevision
        )
        let reset = WebInspectorModelContainerReset(
            commit: commit,
            acknowledgementBarrier: barrier
        )
        detachTransaction = reset
        completedDetachTransaction = nil
        lifecycle = .detaching
        return reset
    }

    /// Completes the canonical detach transaction after all contexts captured
    /// at its reset boundary have applied or unregistered. Cancellation leaves
    /// the same transaction active and retryable.
    package func finishDetach(
        _ transaction: WebInspectorModelContainerReset
    ) async throws {
        if transaction == completedDetachTransaction {
            return
        }
        guard transaction == detachTransaction else {
            throw WebInspectorModelContainerCoreError.detachTransactionMismatch
        }

        try await waitForAcknowledgements(
            transaction.acknowledgementBarrier
        )
        if transaction == completedDetachTransaction {
            return
        }
        guard transaction == detachTransaction else {
            throw WebInspectorModelContainerCoreError.detachTransactionMismatch
        }
        detachTransaction = nil
        completedDetachTransaction = transaction
        switch lifecycle {
        case .detaching:
            lifecycle = .open
        case .closing, .closed:
            break
        case .open:
            preconditionFailure(
                "A pending detach transaction cannot coexist with an open Core."
            )
        }
    }

    /// Captures the materialized contexts that have not yet applied one
    /// canonical revision. Context creation and activation are serialized with
    /// this actor turn, so they fall wholly before or after the boundary.
    package func makeAcknowledgementBarrier(
        through proposedRevision: UInt64
    ) throws(WebInspectorModelContainerCoreError)
        -> WebInspectorModelContextAcknowledgementBarrier
    {
        guard lifecycle == .open || lifecycle == .detaching else {
            throw .closed
        }
        guard proposedRevision <= revision else {
            throw .acknowledgementRevisionAhead(
                current: revision,
                proposed: proposedRevision
            )
        }
        return makeRevisionAcknowledgementBarrier(
            through: proposedRevision
        )
    }

    /// Waits for every context captured by a revision or close boundary.
    /// Cancellation abandons only this wait; the barrier remains retryable.
    package func waitForAcknowledgements(
        _ barrier: WebInspectorModelContextAcknowledgementBarrier
    ) async throws {
        guard barrier.coreIdentity === identity else {
            throw WebInspectorModelContainerCoreError
                .foreignAcknowledgementBarrier
        }
        try await barrier.waiter.wait()
    }

    /// Rejects new work and terminates publication while retaining every
    /// materialized context until its driver closes owner state and unregisters.
    package func beginClose() -> WebInspectorModelContainerClose {
        if let closeTransaction {
            return closeTransaction
        }

        precondition(
            lifecycle == .open || lifecycle == .detaching,
            "A closed Model Container Core must retain its close transaction."
        )
        lifecycle = .closing
        var closingRegistrationIDs: Set<WebInspectorModelContextRegistrationID> = []
        for registrationID in Array(contextRegistrations.keys) {
            guard var registration = contextRegistrations[registrationID] else {
                continue
            }
            let wasClaimed = registration.admission.close()
            switch registration.phase {
            case .reserved:
                guard wasClaimed else {
                    registration.updates.cancel()
                    continue
                }
                registration.phase = .closing
                registration.acknowledgedRevision = nil
                contextRegistrations[registrationID] = registration
                closingRegistrationIDs.insert(registrationID)
            case .active:
                precondition(
                    wasClaimed,
                    "An active context must own its materialization admission."
                )
                registration.phase = .closing
                contextRegistrations[registrationID] = registration
                closingRegistrationIDs.insert(registrationID)
            case .closing:
                precondition(
                    wasClaimed,
                    "A closing context must own its materialization admission."
                )
                closingRegistrationIDs.insert(registrationID)
            }
        }
        let barrier = makeAcknowledgementBarrier(
            requirement: .close,
            revision: revision,
            registrationIDs: closingRegistrationIDs
        )
        let transaction = WebInspectorModelContainerClose(
            acknowledgementBarrier: barrier
        )
        closeTransaction = transaction
        publication.finish()
        return transaction
    }

    /// Commits terminal Core closure only after every materialized context has
    /// invalidated its registry/FRC owner state and unregistered.
    package func finishClose(
        _ transaction: WebInspectorModelContainerClose
    ) async throws {
        guard transaction == closeTransaction else {
            throw WebInspectorModelContainerCoreError.closeTransactionMismatch
        }
        if lifecycle == .closed {
            return
        }

        try await waitForAcknowledgements(
            transaction.acknowledgementBarrier
        )
        if lifecycle == .closed {
            return
        }
        precondition(
            contextRegistrations.values.allSatisfy {
                $0.phase == .reserved
            },
            "A close barrier completed before every materialized context unregistered."
        )
        if let detachTransaction {
            completedDetachTransaction = detachTransaction
            self.detachTransaction = nil
        }
        let registrations = contextRegistrations.values
        contextRegistrations.removeAll(keepingCapacity: false)
        performanceCounters.contextUnregistrationCount += registrations.count
        for registration in registrations {
            registration.updates.cancel()
        }
        lifecycle = .closed

        let waiters = acknowledgementBarriers.values.map(\.waiter)
        acknowledgementBarriers.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.satisfy()
        }
    }
}

private extension WebInspectorModelContainerCore {
    func publish(
        _ transaction: WebInspectorCanonicalModelTransaction
    ) -> WebInspectorCanonicalModelCommit? {
        guard !transaction.isEmpty else {
            performanceCounters.ignoredEmptyTransactionCount += 1
            return nil
        }
        precondition(
            revision < UInt64.max,
            "Model Container Core exhausted canonical revisions."
        )
        let fromRevision = revision
        let toRevision = fromRevision + 1
        publication.publish(
            from: fromRevision,
            to: toRevision,
            changes: transaction
        )
        revision = toRevision
        performanceCounters.publishedTransactionCount += 1
        return WebInspectorCanonicalModelCommit(
            fromRevision: fromRevision,
            toRevision: toRevision,
            transaction: transaction
        )
    }

    func makeRevisionAcknowledgementBarrier(
        through revision: UInt64
    ) -> WebInspectorModelContextAcknowledgementBarrier {
        var registrationIDs: Set<WebInspectorModelContextRegistrationID> = []
        for registrationID in Array(contextRegistrations.keys) {
            guard var registration = contextRegistrations[registrationID]
            else {
                continue
            }
            if registration.phase == .reserved {
                if registration.admission.wasClaimed {
                    registration.phase = .active
                    registration.acknowledgedRevision = nil
                } else {
                    if registration.acknowledgedRevision.map({
                        $0 < revision
                    }) ?? true {
                        registration.acknowledgedRevision = revision
                    }
                    contextRegistrations[registrationID] = registration
                    continue
                }
            }
            if registration.phase != .reserved,
                registration.acknowledgedRevision.map({ $0 < revision }) ?? true
            {
                registrationIDs.insert(registrationID)
            }
            contextRegistrations[registrationID] = registration
        }
        return makeAcknowledgementBarrier(
            requirement: .revision(revision),
            revision: revision,
            registrationIDs: registrationIDs
        )
    }

    private func makeAcknowledgementBarrier(
        requirement: AcknowledgementRequirement,
        revision: UInt64,
        registrationIDs: Set<WebInspectorModelContextRegistrationID>
    ) -> WebInspectorModelContextAcknowledgementBarrier {
        precondition(
            nextAcknowledgementBarrierID < UInt64.max,
            "Model Container Core exhausted acknowledgement barrier identifiers."
        )
        nextAcknowledgementBarrierID += 1
        let barrierID = nextAcknowledgementBarrierID
        let waiter = WebInspectorModelContextAcknowledgementWaiter()
        if registrationIDs.isEmpty {
            waiter.satisfy()
        } else {
            acknowledgementBarriers[barrierID] = AcknowledgementBarrierState(
                requirement: requirement,
                remainingRegistrationIDs: registrationIDs,
                waiter: waiter
            )
        }
        return WebInspectorModelContextAcknowledgementBarrier(
            coreIdentity: identity,
            id: barrierID,
            waiter: waiter,
            revision: revision
        )
    }

    func resumeSatisfiedBarriers(
        afterAcknowledging registrationID: WebInspectorModelContextRegistrationID,
        through revision: UInt64
    ) {
        var waiters: [WebInspectorModelContextAcknowledgementWaiter] = []
        for barrierID in Array(acknowledgementBarriers.keys) {
            guard var barrier = acknowledgementBarriers[barrierID] else {
                continue
            }
            guard case let .revision(requiredRevision) = barrier.requirement,
                requiredRevision <= revision
            else {
                continue
            }
            barrier.remainingRegistrationIDs.remove(registrationID)
            if barrier.remainingRegistrationIDs.isEmpty {
                waiters.append(barrier.waiter)
                acknowledgementBarriers[barrierID] = nil
            } else {
                acknowledgementBarriers[barrierID] = barrier
            }
        }
        for waiter in waiters {
            waiter.satisfy()
        }
    }

    func resumeSatisfiedBarriers(
        afterRemoving registrationID: WebInspectorModelContextRegistrationID
    ) {
        var waiters: [WebInspectorModelContextAcknowledgementWaiter] = []
        for barrierID in Array(acknowledgementBarriers.keys) {
            guard var barrier = acknowledgementBarriers[barrierID] else {
                continue
            }
            barrier.remainingRegistrationIDs.remove(registrationID)
            if barrier.remainingRegistrationIDs.isEmpty {
                waiters.append(barrier.waiter)
                acknowledgementBarriers[barrierID] = nil
            } else {
                acknowledgementBarriers[barrierID] = barrier
            }
        }
        for waiter in waiters {
            waiter.satisfy()
        }
    }
}

private final class WebInspectorModelContainerCoreIdentity: Sendable {}

private final class WebInspectorModelContextAdmissionGate: Sendable {
    private enum State {
        case reserved
        case claimed
        case closed(wasClaimed: Bool)
    }

    private let state = Mutex(State.reserved)

    var wasClaimed: Bool {
        state.withLock { state in
            switch state {
            case .reserved:
                false
            case .claimed:
                true
            case let .closed(wasClaimed):
                wasClaimed
            }
        }
    }

    var isClosed: Bool {
        state.withLock { state in
            if case .closed = state {
                true
            } else {
                false
            }
        }
    }

    func claim() -> WebInspectorModelContextMaterializationClaim {
        state.withLock { state in
            switch state {
            case .reserved:
                state = .claimed
                return .admitted
            case .claimed:
                preconditionFailure(
                    "A model context registration supports one materialization owner."
                )
            case .closed:
                return .closed
            }
        }
    }

    /// Returns whether a materialization owner won before terminal close.
    func close() -> Bool {
        state.withLock { state in
            switch state {
            case .reserved:
                state = .closed(wasClaimed: false)
                return false
            case .claimed:
                state = .closed(wasClaimed: true)
                return true
            case let .closed(wasClaimed):
                return wasClaimed
            }
        }
    }

    func abandon() -> Bool {
        state.withLock { state in
            switch state {
            case .reserved:
                state = .closed(wasClaimed: false)
                return true
            case .closed(wasClaimed: false):
                return true
            case .claimed, .closed(wasClaimed: true):
                return false
            }
        }
    }
}

private final class WebInspectorModelContextAcknowledgementWaiter: Sendable {
    private enum Delivery: Sendable {
        case satisfied
        case cancelled
    }

    private struct State {
        var isSatisfied = false
        var nextWaiterID: UInt64 = 0
        var cancelledWaiterIDs: Set<UInt64> = []
        var continuations: [UInt64: CheckedContinuation<Delivery, Never>] = [:]
    }

    private let state = Mutex(State())

    func wait() async throws(CancellationError) {
        let waiterID = state.withLock { state in
            precondition(
                state.nextWaiterID < UInt64.max,
                "Model context acknowledgement waiter exhausted identifiers."
            )
            state.nextWaiterID += 1
            return state.nextWaiterID
        }
        let delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Delivery? in
                    if state.isSatisfied {
                        return .satisfied
                    }
                    if state.cancelledWaiterIDs.remove(waiterID) != nil {
                        return .cancelled
                    }
                    precondition(
                        state.continuations[waiterID] == nil,
                        "An acknowledgement waiter identifier must be unique."
                    )
                    state.continuations[waiterID] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                }
            }
        } onCancel: { [self] in
            cancel(waiterID)
        }

        switch delivery {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        }
    }

    func satisfy() {
        let continuations = state.withLock { state in
            guard state.isSatisfied == false else {
                return [CheckedContinuation<Delivery, Never>]()
            }
            state.isSatisfied = true
            state.cancelledWaiterIDs.removeAll(keepingCapacity: false)
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: .satisfied)
        }
    }

    private func cancel(_ waiterID: UInt64) {
        let continuation: CheckedContinuation<Delivery, Never>? =
            state.withLock { state in
                guard state.isSatisfied == false else {
                    return nil
                }
                guard
                    let continuation = state.continuations.removeValue(
                        forKey: waiterID
                    )
                else {
                    state.cancelledWaiterIDs.insert(waiterID)
                    return nil
                }
                return continuation
            }
        continuation?.resume(returning: .cancelled)
    }
}

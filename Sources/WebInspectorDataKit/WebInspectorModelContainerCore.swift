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
    case detached
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
    case foreignSynchronizationCheckpoint
    case staleSynchronizationGeneration(
        expected: WebInspectorContainerAttachmentGeneration,
        actual: WebInspectorContainerAttachmentGeneration
    )
    case synchronizationFailed(WebInspectorModelContainer.Failure)
}

package struct WebInspectorModelContainerSynchronizationCursor:
    Equatable,
    Sendable
{
    fileprivate let coreIdentity: WebInspectorModelContainerCoreIdentity
    fileprivate let attachmentGeneration:
        WebInspectorContainerAttachmentGeneration
    fileprivate let ordinal: UInt64
    fileprivate let revision: UInt64

    package static func == (
        lhs: WebInspectorModelContainerSynchronizationCursor,
        rhs: WebInspectorModelContainerSynchronizationCursor
    ) -> Bool {
        lhs.coreIdentity === rhs.coreIdentity
            && lhs.attachmentGeneration == rhs.attachmentGeneration
            && lhs.ordinal == rhs.ordinal
            && lhs.revision == rhs.revision
    }
}

package enum WebInspectorNetworkResponseBodyCommandError: Error, Equatable, Sendable {
    case closed
    case detached
    case domainNotConfigured
    case foreignStore
    case staleRequest
    case requestNotFound
    case agentTargetUnavailable(WebInspectorTarget.ID)
    case responseMissing
    case responseNotFinished
    case webSocketIneligible
    case staleResponse
    case proxy(WebInspectorProxyError)
    case authorization(ConnectionModelCommandError)
    case invalidReply(String)
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
    package fileprivate(set) var networkResponseBodyWireCommandCount = 0
    package fileprivate(set) var networkResponseBodyCoalescedWaiterCount = 0
    package fileprivate(set) var networkResponseBodyInvalidationCount = 0
    package var domCSSCommandWireOperationCount = 0
    package var domCSSCommandCoalescedWaiterCount = 0
    package var domCSSCommandInvalidationCount = 0
}

package struct WebInspectorModelContainerCoreMetrics: Equatable, Sendable {
    package let revision: UInt64
    package let activeContextRegistrationCount: Int
    package let networkResponseBodyOperationCount: Int
    package let domCSSCommandOperationCount: Int
    package let elementPickerOperationCount: Int
    package let core: WebInspectorModelContainerCorePerformanceCounters
    package let canonicalStore: WebInspectorCanonicalModelStorePerformanceCounters
}

/// The single ordered owner of canonical inspection state and context
/// publication, including attachment-attempt and Proxy/feed teardown ordering.
///
/// Native `WKWebView` Proxy construction stays at the MainActor boundary; the
/// resulting Sendable Proxy is transferred here. This actor contains no UI,
/// Observable model, query, or domain-specific reduction. Feed semantics remain
/// in the pure canonical store and subscriber coalescing remains in the
/// synchronized publication.
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

    private struct SynchronizationWaiterState {
        let checkpoint: WebInspectorModelContainerSynchronizationCursor
        let waiter: WebInspectorModelContainerSynchronizationWaiter
    }

    private struct NetworkResponseBodyCommandRoute: Sendable {
        let lease: CanonicalNetworkResponseBodyLease
        let resourceID: UInt64
        let attachmentGeneration: WebInspectorContainerAttachmentGeneration
        let pageGeneration: WebInspectorPage.Generation
        let agentTarget: ModelTarget
        let rawRequestID: Network.Request.ID
        let backendResourceIdentifier: Network.BackendResourceID?
        let proxy: WebInspectorProxy
        let feedID: ConnectionModelFeedID

        func hasSameAuthority(
            as other: NetworkResponseBodyCommandRoute
        ) -> Bool {
            lease == other.lease
                && resourceID == other.resourceID
                && attachmentGeneration == other.attachmentGeneration
                && pageGeneration == other.pageGeneration
                && agentTarget == other.agentTarget
                && rawRequestID == other.rawRequestID
                && backendResourceIdentifier
                    == other.backendResourceIdentifier
                && proxy === other.proxy
                && feedID == other.feedID
        }
    }

    private struct NetworkResponseBodyCommandOperation: Sendable {
        let route: NetworkResponseBodyCommandRoute
        let completion: ReplyPromise<Network.Body>
        let task: Task<Void, Never>
        var isRetired: Bool
    }

    package nonisolated let storeID: WebInspectorContainerStoreID
    package nonisolated let configuredDomains: Set<ModelDomain>
    package nonisolated let modelSchemaRegistry: WebInspectorModelSchemaRegistry
    package nonisolated let mainContextSeed: WebInspectorModelContextSeed
    package nonisolated let connectionStatePublication: WebInspectorModelContainerStatePublication

    private nonisolated let publication: Publication
    private nonisolated let identity = WebInspectorModelContainerCoreIdentity()
    var canonicalStore: WebInspectorCanonicalModelStore
    private var revision: UInt64 = 0
    private var lifecycle = Lifecycle.open
    private var nextContextRegistrationID: UInt64 = 0
    private var contextRegistrations: [WebInspectorModelContextRegistrationID: ContextRegistrationState] = [:]
    private var nextAcknowledgementBarrierID: UInt64 = 0
    private var acknowledgementBarriers: [UInt64: AcknowledgementBarrierState] = [:]
    private var nextSynchronizationOrdinal: UInt64 = 0
    private var latestSynchronizationCursorByGeneration:
        [
            WebInspectorContainerAttachmentGeneration:
                WebInspectorModelContainerSynchronizationCursor
        ] = [:]
    private var nextSynchronizationWaiterID: UInt64 = 0
    private var synchronizationWaiters:
        [UInt64: SynchronizationWaiterState] = [:]
    private var detachTransaction: WebInspectorModelContainerReset?
    private var completedDetachTransactionID: UInt64?
    private var closeTransaction: WebInspectorModelContainerClose?
    private var nextNetworkResponseBodyCommandOperationID: UInt64 = 0
    private var networkResponseBodyOperationIDByLease: [CanonicalNetworkResponseBodyLease: UInt64] = [:]
    private var networkResponseBodyOperations: [UInt64: NetworkResponseBodyCommandOperation] = [:]
    package var runtimeCommandGatewayState =
        WebInspectorRuntimeCommandGatewayState()
    var nextDOMCSSCommandOperationID: UInt64 = 0
    var domCSSCommandOperations: [UInt64: WebInspectorDOMCSSCommandOperation] = [:]
    var domCSSOperationIDByCSSResourceLease: [WebInspectorCanonicalCSSResourceLease: UInt64] = [:]
    var domCSSResourceCompletions: [UInt64: ReplyPromise<WebInspectorCanonicalCSSResource>] = [:]
    var nextElementPickerOperationID: UInt64 = 0
    var elementPickerOperation: WebInspectorElementPickerOperationState?
    var performanceCounters =
        WebInspectorModelContainerCorePerformanceCounters()
    package var nextAttachmentGeneration: UInt64 = 0
    package var nextFeedResourceID: UInt64 = 0
    package var attachmentAttempts:
        [WebInspectorContainerAttachmentGeneration:
            WebInspectorModelContainerAttachmentAttemptState] = [:]
    package var activeAttachment: WebInspectorModelContainerAttachmentResource?
    package var lifecycleOperationTail: ReplyPromise<Void>
    package var connectionCloseCompletion: ReplyPromise<Void>?
    package var isConnectionCloseRequested = false

    package init(
        storeID: WebInspectorContainerStoreID = WebInspectorContainerStoreID(),
        configuredDomains: Set<ModelDomain>,
        modelSchemaRegistry: WebInspectorModelSchemaRegistry,
        connectionStatePublication:
            WebInspectorModelContainerStatePublication =
            WebInspectorModelContainerStatePublication()
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
        let lifecycleOperationTail = ReplyPromise<Void>()
        lifecycleOperationTail.fulfill(.success(()))

        self.storeID = storeID
        self.canonicalStore = canonicalStore
        self.configuredDomains = canonicalStore.configuredDomains
        self.modelSchemaRegistry = modelSchemaRegistry
        self.publication = publication
        self.connectionStatePublication = connectionStatePublication
        self.lifecycleOperationTail = lifecycleOperationTail
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

    package var hasCanonicalBinding: Bool {
        canonicalStore.bindingSnapshot != nil
    }

    package nonisolated var connectionState: WebInspectorModelContainer.State {
        connectionStatePublication.current
    }

    package nonisolated var connectionStateUpdates: WebInspectorModelContainer.StateUpdateSequence {
        connectionStatePublication.subscribe()
    }

    package var isClosed: Bool {
        lifecycle == .closed
    }

    package var synchronizationWaiterCountForTesting: Int {
        synchronizationWaiters.count
    }

    package func synchronizationCheckpoint()
        throws(WebInspectorModelContainerCoreError)
        -> WebInspectorModelContainerSynchronizationCursor
    {
        guard !isConnectionCloseRequested, lifecycle == .open else {
            throw .closed
        }
        guard let generation = activeAttachment?.generation else {
            throw .detached
        }
        guard let cursor = latestSynchronizationCursorByGeneration[generation]
        else {
            preconditionFailure(
                "An attached Model Container must retain its completed initial synchronization."
            )
        }
        return cursor
    }

    package func waitForSynchronization(
        after checkpoint: WebInspectorModelContainerSynchronizationCursor
    ) async throws -> WebInspectorModelContainerSynchronizationCursor {
        guard checkpoint.coreIdentity === identity else {
            throw WebInspectorModelContainerCoreError
                .foreignSynchronizationCheckpoint
        }
        guard !isConnectionCloseRequested, lifecycle == .open else {
            throw WebInspectorModelContainerCoreError.closed
        }
        guard let generation = activeAttachment?.generation else {
            throw WebInspectorModelContainerCoreError.detached
        }
        guard checkpoint.attachmentGeneration == generation else {
            throw WebInspectorModelContainerCoreError
                .staleSynchronizationGeneration(
                    expected: generation,
                    actual: checkpoint.attachmentGeneration
                )
        }
        guard let cursor = latestSynchronizationCursorByGeneration[generation]
        else {
            preconditionFailure(
                "An attached Model Container must retain its completed initial synchronization."
            )
        }
        precondition(
            checkpoint.ordinal <= cursor.ordinal
                && checkpoint.revision <= cursor.revision,
            "A synchronization checkpoint cannot lead its attachment generation."
        )
        if cursor.ordinal > checkpoint.ordinal {
            return cursor
        }

        precondition(
            nextSynchronizationWaiterID < UInt64.max,
            "Model Container exhausted synchronization waiter identifiers."
        )
        nextSynchronizationWaiterID += 1
        let waiterID = nextSynchronizationWaiterID
        let waiter = WebInspectorModelContainerSynchronizationWaiter()
        synchronizationWaiters[waiterID] = SynchronizationWaiterState(
            checkpoint: checkpoint,
            waiter: waiter
        )
        do {
            let cursor = try await waiter.wait()
            synchronizationWaiters[waiterID] = nil
            return cursor
        } catch {
            synchronizationWaiters[waiterID] = nil
            throw error
        }
    }

    package func runtimeCommandEnvironment()
        throws(WebInspectorRuntimeCommandGatewayError)
        -> WebInspectorRuntimeCommandEnvironment
    {
        guard !isConnectionCloseRequested,
            lifecycle == .open
        else {
            throw .closed
        }
        guard let resource = activeAttachment,
            let binding = canonicalStore.bindingSnapshot
        else {
            throw .detached
        }
        precondition(
            resource.generation == binding.attachmentGeneration,
            "Runtime command authority crossed attachment generations."
        )
        return WebInspectorRuntimeCommandEnvironment(
            resourceID: resource.id,
            attachmentGeneration: resource.generation,
            pageGeneration: binding.pageGeneration,
            currentPageID: binding.currentPageID,
            targets: binding.targets,
            proxy: resource.proxyLease.proxy,
            feedID: resource.feed.id
        )
    }

    package func runtimeCommandConsoleMessage(
        for id: CanonicalConsoleMessageIDStorage
    ) -> CanonicalConsoleMessageRecord? {
        canonicalStore.consoleMessage(for: id)
    }

    package func runtimeCommandContext(
        for id: CanonicalRuntimeContextIDStorage
    ) -> CanonicalRuntimeContextRecord? {
        canonicalStore.runtimeContext(for: id)
    }

    var acceptsDOMCSSCommands: Bool {
        lifecycle == .open
    }

    package var metrics: WebInspectorModelContainerCoreMetrics {
        WebInspectorModelContainerCoreMetrics(
            revision: revision,
            activeContextRegistrationCount: contextRegistrations.values.count {
                $0.phase.isMaterialized || $0.admission.wasClaimed
            },
            networkResponseBodyOperationCount:
                networkResponseBodyOperations.count,
            domCSSCommandOperationCount: domCSSCommandOperations.count,
            elementPickerOperationCount: elementPickerOperation == nil ? 0 : 1,
            core: performanceCounters,
            canonicalStore: canonicalStore.performanceCounters
        )
    }

    #if DEBUG
        package func canonicalSnapshotForTesting()
            -> WebInspectorCanonicalModelSnapshot
        {
            canonicalStore.snapshot(reason: .onDemandRebase)
        }
    #endif

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
        guard !isConnectionCloseRequested,
            lifecycle == .open || lifecycle == .detaching
        else {
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
        guard !isConnectionCloseRequested,
            lifecycle == .open || lifecycle == .detaching
        else {
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
        invalidateStaleNetworkResponseBodyOperations()
        applyRuntimeCommandInvalidations(from: transaction)
        invalidateStaleDOMCSSOperations(applying: transaction)
        return publish(transaction)
    }

    /// Publishes one canonical Network clear and returns only after every
    /// materialized context at the commit boundary has applied or unregistered.
    package func clearNetworkRequests() async throws {
        guard lifecycle == .open else {
            if lifecycle == .detaching {
                throw WebInspectorModelContainerCoreError.detachInProgress
            }
            throw WebInspectorModelContainerCoreError.closed
        }
        let transaction = canonicalStore.clearNetworkRequests()
        invalidateStaleNetworkResponseBodyOperations()
        guard let commit = publish(transaction) else {
            return
        }
        let barrier = makeRevisionAcknowledgementBarrier(
            through: commit.toRevision
        )
        try await waitForAcknowledgements(barrier)
    }

    /// Loads one current canonical response body through the physical Network
    /// agent that allocated its opaque request identifier.
    ///
    /// The Core owns admission and cross-context coalescing. Cancelling one
    /// caller removes only that caller's wait; attachment and canonical-state
    /// invalidation own cancellation of the shared wire operation.
    package func loadNetworkResponseBody(
        for requestID: CanonicalNetworkRequestIDStorage
    ) async throws -> Network.Body {
        try Task.checkCancellation()
        let completion = try claimNetworkResponseBodyOperation(
            for: requestID
        )
        return try await completion.value()
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
        retireAllNetworkResponseBodyOperations(with: .detached)
        retireAllDOMCSSOperations(with: .detached)
        let transaction = canonicalStore.clearForDetach()
        applyRuntimeCommandInvalidations(from: transaction)
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
        completedDetachTransactionID = nil
        lifecycle = .detaching
        return reset
    }

    /// Completes the canonical detach transaction after all contexts captured
    /// at its reset boundary have applied or unregistered. Cancellation leaves
    /// the same transaction active and retryable.
    package func finishDetach(
        _ transaction: WebInspectorModelContainerReset
    ) async throws {
        if isCompletedDetachTransaction(transaction) {
            return
        }
        guard transaction == detachTransaction else {
            throw WebInspectorModelContainerCoreError.detachTransactionMismatch
        }

        try await waitForAcknowledgements(
            transaction.acknowledgementBarrier
        )
        await waitForNetworkResponseBodyOperationsToFinish()
        await waitForRuntimeCommandOperationsToFinish()
        discardRuntimeCommandTombstonesAfterDetach()
        await waitForDOMCSSOperationsToFinish()
        if isCompletedDetachTransaction(transaction) {
            return
        }
        guard transaction == detachTransaction else {
            throw WebInspectorModelContainerCoreError.detachTransactionMismatch
        }
        detachTransaction = nil
        completedDetachTransactionID =
            transaction.acknowledgementBarrier.id
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
        retireAllNetworkResponseBodyOperations(with: .closed)
        invalidateAllRuntimeCommandResources(with: .closed)
        retireAllDOMCSSOperations(with: .closed)
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
        await waitForNetworkResponseBodyOperationsToFinish()
        await waitForRuntimeCommandOperationsToFinish()
        await waitForDOMCSSOperationsToFinish()
        if lifecycle == .closed {
            return
        }
        precondition(
            contextRegistrations.values.allSatisfy {
                $0.phase == .reserved
            },
            "A close barrier completed before every materialized context unregistered."
        )
        completedDetachTransactionID =
            detachTransaction?.acknowledgementBarrier.id
            ?? completedDetachTransactionID
        detachTransaction = nil
        let registrations = contextRegistrations.values
        contextRegistrations.removeAll(keepingCapacity: false)
        performanceCounters.contextUnregistrationCount += registrations.count
        for registration in registrations {
            registration.updates.cancel()
        }
        canonicalStore.releaseSemanticStorageForClose()
        releaseRuntimeCommandStorageForClose()
        lifecycle = .closed

        let waiters = acknowledgementBarriers.values.map(\.waiter)
        acknowledgementBarriers.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.satisfy()
        }
    }

    private func isCompletedDetachTransaction(
        _ transaction: WebInspectorModelContainerReset
    ) -> Bool {
        transaction.acknowledgementBarrier.coreIdentity === identity
            && transaction.acknowledgementBarrier.id
                == completedDetachTransactionID
    }
}

private extension WebInspectorModelContainerCore {
    func claimNetworkResponseBodyOperation(
        for requestID: CanonicalNetworkRequestIDStorage
    ) throws -> ReplyPromise<Network.Body> {
        let route = try networkResponseBodyRoute(for: requestID)
        if let operationID = networkResponseBodyOperationIDByLease[route.lease] {
            guard let operation = networkResponseBodyOperations[operationID],
                !operation.isRetired
            else {
                preconditionFailure(
                    "A Network response-body lease lost its active operation."
                )
            }
            precondition(
                operation.route.hasSameAuthority(as: route),
                "Canonical Network command authority changed without advancing its response-body revision."
            )
            performanceCounters.networkResponseBodyCoalescedWaiterCount += 1
            return operation.completion
        }

        precondition(
            nextNetworkResponseBodyCommandOperationID < UInt64.max,
            "Model Container Core exhausted Network response-body operation identifiers."
        )
        nextNetworkResponseBodyCommandOperationID += 1
        let operationID = nextNetworkResponseBodyCommandOperationID
        let completion = ReplyPromise<Network.Body>()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Self.performNetworkResponseBodyCommand(route)
            guard let self else {
                completion.fulfill(
                    .failure(WebInspectorNetworkResponseBodyCommandError.closed)
                )
                return
            }
            await self.finishNetworkResponseBodyOperation(
                operationID,
                result: result
            )
        }
        let operation = NetworkResponseBodyCommandOperation(
            route: route,
            completion: completion,
            task: task,
            isRetired: false
        )
        precondition(
            networkResponseBodyOperations[operationID] == nil,
            "A Network response-body operation identifier was reused."
        )
        precondition(
            networkResponseBodyOperationIDByLease[route.lease] == nil,
            "A Network response-body lease admitted two wire operations."
        )
        networkResponseBodyOperations[operationID] = operation
        networkResponseBodyOperationIDByLease[route.lease] = operationID
        performanceCounters.networkResponseBodyWireCommandCount += 1
        return completion
    }

    private func networkResponseBodyRoute(
        for requestID: CanonicalNetworkRequestIDStorage
    ) throws -> NetworkResponseBodyCommandRoute {
        guard !isConnectionCloseRequested,
            lifecycle == .open
        else {
            throw WebInspectorNetworkResponseBodyCommandError.closed
        }
        guard configuredDomains.contains(.network) else {
            throw WebInspectorNetworkResponseBodyCommandError
                .domainNotConfigured
        }
        guard requestID.storeID == storeID else {
            throw WebInspectorNetworkResponseBodyCommandError.foreignStore
        }
        guard let resource = activeAttachment,
            let binding = canonicalStore.bindingSnapshot
        else {
            throw WebInspectorNetworkResponseBodyCommandError.detached
        }
        guard resource.generation == requestID.attachmentGeneration,
            binding.attachmentGeneration == requestID.attachmentGeneration,
            binding.pageGeneration == requestID.pageGeneration
        else {
            throw WebInspectorNetworkResponseBodyCommandError.staleRequest
        }
        guard let record = canonicalStore.networkRequest(for: requestID) else {
            throw WebInspectorNetworkResponseBodyCommandError.requestNotFound
        }
        guard record.webSocket == nil else {
            throw WebInspectorNetworkResponseBodyCommandError
                .webSocketIneligible
        }
        guard record.currentHop.response != nil else {
            throw WebInspectorNetworkResponseBodyCommandError.responseMissing
        }
        guard record.lifecycle == .finished else {
            throw WebInspectorNetworkResponseBodyCommandError
                .responseNotFinished
        }
        guard
            let agentTarget = binding.targets.lazy
                .map(\.target)
                .first(where: { $0.id == requestID.agentTargetID })
        else {
            throw
                WebInspectorNetworkResponseBodyCommandError
                .agentTargetUnavailable(requestID.agentTargetID)
        }

        return NetworkResponseBodyCommandRoute(
            lease: CanonicalNetworkResponseBodyLease(
                requestID: requestID,
                responseRevision: record.responseBodyRevision
            ),
            resourceID: resource.id,
            attachmentGeneration: resource.generation,
            pageGeneration: binding.pageGeneration,
            agentTarget: agentTarget,
            rawRequestID: record.currentHop.request.rawID,
            backendResourceIdentifier: record.currentHop.request
                .backendResourceIdentifier.map {
                    Network.BackendResourceID(
                        sourceProcessID: $0.sourceProcessID,
                        resourceID: $0.resourceID
                    )
                },
            proxy: resource.proxyLease.proxy,
            feedID: resource.feed.id
        )
    }

    private nonisolated static func performNetworkResponseBodyCommand(
        _ route: NetworkResponseBodyCommandRoute
    ) async -> Result<Network.Body, WebInspectorNetworkResponseBodyCommandError> {
        let target = route.proxy.modelTarget(
            route.agentTarget,
            authorization: ConnectionModelCommandAuthorization(
                feedID: route.feedID,
                generation: route.pageGeneration
            )
        )
        do {
            return .success(
                try await target.network.responseBody(
                    for: route.rawRequestID,
                    backendResourceIdentifier: route.backendResourceIdentifier
                )
            )
        } catch let error as WebInspectorProxyError {
            return .failure(.proxy(error))
        } catch let error as ConnectionModelCommandError {
            return .failure(.authorization(error))
        } catch is CancellationError {
            return .failure(.staleResponse)
        } catch {
            return .failure(.invalidReply(String(reflecting: error)))
        }
    }

    func finishNetworkResponseBodyOperation(
        _ operationID: UInt64,
        result: Result<Network.Body, WebInspectorNetworkResponseBodyCommandError>
    ) {
        guard
            let operation = networkResponseBodyOperations.removeValue(
                forKey: operationID
            )
        else {
            preconditionFailure(
                "A Network response-body operation completed without its Core owner."
            )
        }
        if networkResponseBodyOperationIDByLease[operation.route.lease]
            == operationID
        {
            networkResponseBodyOperationIDByLease[operation.route.lease] = nil
        }
        guard !operation.isRetired else {
            return
        }

        if let validationError = networkResponseBodyCompletionError(
            for: operation.route
        ) {
            precondition(
                operation.completion.fulfill(.failure(validationError)),
                "A current Network response-body operation completed twice."
            )
        } else {
            precondition(
                operation.completion.fulfill(result.mapError { $0 as any Error }),
                "A current Network response-body operation completed twice."
            )
        }
    }

    private func networkResponseBodyCompletionError(
        for route: NetworkResponseBodyCommandRoute
    ) -> WebInspectorNetworkResponseBodyCommandError? {
        if isConnectionCloseRequested
            || lifecycle == .closing
            || lifecycle == .closed
        {
            return .closed
        }
        guard lifecycle == .open,
            let resource = activeAttachment
        else {
            return .detached
        }
        guard resource.id == route.resourceID,
            resource.generation == route.attachmentGeneration,
            resource.feed.id == route.feedID,
            resource.proxyLease.proxy === route.proxy,
            let binding = canonicalStore.bindingSnapshot,
            binding.attachmentGeneration == route.attachmentGeneration,
            binding.pageGeneration == route.pageGeneration,
            binding.targets.contains(where: { $0.target == route.agentTarget }),
            let record = canonicalStore.networkRequest(
                for: route.lease.requestID
            ),
            record.responseBodyRevision == route.lease.responseRevision,
            record.lifecycle == .finished,
            record.webSocket == nil,
            record.currentHop.response != nil,
            record.currentHop.request.rawID == route.rawRequestID,
            networkBackendResourceIdentifier(
                for: record
            ) == route.backendResourceIdentifier
        else {
            return .staleResponse
        }
        return nil
    }

    func networkBackendResourceIdentifier(
        for record: CanonicalNetworkRequestRecord
    ) -> Network.BackendResourceID? {
        record.currentHop.request.backendResourceIdentifier.map {
            Network.BackendResourceID(
                sourceProcessID: $0.sourceProcessID,
                resourceID: $0.resourceID
            )
        }
    }

    func invalidateStaleNetworkResponseBodyOperations() {
        for operationID in networkResponseBodyOperations.keys.sorted() {
            guard let operation = networkResponseBodyOperations[operationID],
                !operation.isRetired,
                let error = networkResponseBodyCompletionError(
                    for: operation.route
                )
            else {
                continue
            }
            retireNetworkResponseBodyOperation(
                operationID,
                with: error
            )
        }
    }

    func retireAllNetworkResponseBodyOperations(
        with error: WebInspectorNetworkResponseBodyCommandError
    ) {
        for operationID in networkResponseBodyOperations.keys.sorted() {
            retireNetworkResponseBodyOperation(
                operationID,
                with: error
            )
        }
    }

    func retireNetworkResponseBodyOperation(
        _ operationID: UInt64,
        with error: WebInspectorNetworkResponseBodyCommandError
    ) {
        guard var operation = networkResponseBodyOperations[operationID],
            !operation.isRetired
        else {
            return
        }
        operation.isRetired = true
        networkResponseBodyOperations[operationID] = operation
        if networkResponseBodyOperationIDByLease[operation.route.lease]
            == operationID
        {
            networkResponseBodyOperationIDByLease[operation.route.lease] = nil
        }
        precondition(
            operation.completion.fulfill(.failure(error)),
            "A Network response-body operation was invalidated twice."
        )
        operation.task.cancel()
        performanceCounters.networkResponseBodyInvalidationCount += 1
    }

    func waitForNetworkResponseBodyOperationsToFinish() async {
        let tasks = networkResponseBodyOperations.values.map(\.task)
        for task in tasks {
            await task.value
        }
        precondition(
            networkResponseBodyOperations.isEmpty,
            "Model Container lifecycle completed before Network response-body commands quiesced."
        )
        precondition(
            networkResponseBodyOperationIDByLease.isEmpty,
            "Model Container lifecycle retained an active Network response-body lease."
        )
    }

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

package extension WebInspectorModelContainerCore {
    func recordSynchronizationCompletion(
        resourceID: UInt64,
        generation: WebInspectorContainerAttachmentGeneration,
        through revision: UInt64
    ) throws(WebInspectorModelContainerCoreError) {
        guard !isConnectionCloseRequested, lifecycle == .open else {
            throw .closed
        }
        let isActiveResource = activeAttachment.map {
            $0.id == resourceID && $0.generation == generation
        } ?? false
        let isProvisionalResource = attachmentAttempts[generation]?
            .provisionalResource?.id == resourceID
        guard isActiveResource || isProvisionalResource else {
            guard let activeGeneration = activeAttachment?.generation else {
                throw .detached
            }
            throw .staleSynchronizationGeneration(
                expected: activeGeneration,
                actual: generation
            )
        }
        precondition(
            revision <= self.revision,
            "A synchronization completion cannot acknowledge a future canonical revision."
        )
        precondition(
            nextSynchronizationOrdinal < UInt64.max,
            "Model Container exhausted synchronization cursor ordinals."
        )
        nextSynchronizationOrdinal += 1
        let cursor = WebInspectorModelContainerSynchronizationCursor(
            coreIdentity: identity,
            attachmentGeneration: generation,
            ordinal: nextSynchronizationOrdinal,
            revision: revision
        )
        if let previous = latestSynchronizationCursorByGeneration[generation] {
            precondition(
                previous.ordinal < cursor.ordinal
                    && previous.revision <= cursor.revision,
                "Model Container synchronization cursors must advance monotonically."
            )
        }
        latestSynchronizationCursorByGeneration[generation] = cursor

        for waiterID in Array(synchronizationWaiters.keys) {
            guard let state = synchronizationWaiters[waiterID] else {
                continue
            }
            guard state.checkpoint.attachmentGeneration == generation,
                state.checkpoint.ordinal < cursor.ordinal
            else {
                continue
            }
            synchronizationWaiters[waiterID] = nil
            state.waiter.finish(.success(cursor))
        }
    }

    func retireSynchronizationGeneration(
        _ generation: WebInspectorContainerAttachmentGeneration,
        with error: WebInspectorModelContainerCoreError
    ) {
        latestSynchronizationCursorByGeneration[generation] = nil
        failSynchronizationWaiters(for: generation, with: error)
    }

    func retireAllSynchronizationGenerations(
        with error: WebInspectorModelContainerCoreError
    ) {
        latestSynchronizationCursorByGeneration.removeAll(keepingCapacity: false)
        failSynchronizationWaiters(with: error)
    }

    private func failSynchronizationWaiters(
        for generation: WebInspectorContainerAttachmentGeneration? = nil,
        with error: WebInspectorModelContainerCoreError
    ) {
        for waiterID in Array(synchronizationWaiters.keys) {
            guard let state = synchronizationWaiters[waiterID] else {
                continue
            }
            guard generation.map({
                $0 == state.checkpoint.attachmentGeneration
            }) ?? true else {
                continue
            }
            synchronizationWaiters[waiterID] = nil
            state.waiter.finish(.failure(error))
        }
    }
}

fileprivate final class WebInspectorModelContainerCoreIdentity: Sendable {}

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

private final class WebInspectorModelContainerSynchronizationWaiter: Sendable {
    private enum Delivery: Sendable {
        case completed(
            Result<
                WebInspectorModelContainerSynchronizationCursor,
                WebInspectorModelContainerCoreError
            >
        )
        case cancelled
    }

    private struct State {
        var delivery: Delivery?
        var continuation: CheckedContinuation<Delivery, Never>?
    }

    private let state = Mutex(State())

    func wait() async throws -> WebInspectorModelContainerSynchronizationCursor {
        let delivery = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> Delivery? in
                    if let delivery = state.delivery {
                        return delivery
                    }
                    precondition(
                        state.continuation == nil,
                        "A synchronization waiter supports one caller."
                    )
                    state.continuation = continuation
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
        case let .completed(result):
            return try result.get()
        case .cancelled:
            throw CancellationError()
        }
    }

    func finish(
        _ result: Result<
            WebInspectorModelContainerSynchronizationCursor,
            WebInspectorModelContainerCoreError
        >
    ) {
        complete(.completed(result))
    }

    private func cancel() {
        complete(.cancelled)
    }

    private func complete(_ delivery: Delivery) {
        let continuation: CheckedContinuation<Delivery, Never>? =
            state.withLock { state in
                guard case nil = state.delivery else {
                    return nil
                }
                state.delivery = delivery
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
        continuation?.resume(returning: delivery)
    }
}

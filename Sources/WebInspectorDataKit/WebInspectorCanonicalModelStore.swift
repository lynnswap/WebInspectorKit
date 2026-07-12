import WebInspectorProxyKit

package enum WebInspectorCanonicalFeedProtocolViolation: Error, Equatable, Sendable {
    case staleAttachment(
        expected: WebInspectorContainerAttachmentGeneration,
        actual: WebInspectorContainerAttachmentGeneration
    )
    case nonmonotonicReset(
        currentAttachment: WebInspectorContainerAttachmentGeneration?,
        currentPage: WebInspectorPage.Generation?,
        proposedAttachment: WebInspectorContainerAttachmentGeneration,
        proposedPage: WebInspectorPage.Generation
    )
    case recordBeforeReset
    case generationMismatch(
        expected: WebInspectorPage.Generation,
        actual: WebInspectorPage.Generation
    )
    case sequenceDidNotAdvance(previous: UInt64?, proposed: UInt64)
    case watermarkMovedBackward(previous: UInt64?, proposed: UInt64)
    case duplicateTargetSnapshot
    case invalidTargetSnapshot
    case eventBeforeTargetSnapshot
    case unconfiguredDomain(ModelDomain)
    case invalidReplayDomain(ModelDomain)
    case invalidBootstrapDomain(ModelDomain)
    case bootstrapPayloadMismatch(ModelDomain)
    case duplicateDomainBoundary(ModelDomain)
    case domainCompletedBeforeAuthority(ModelDomain)
    case synchronizationCompletedTwice
    case synchronizationCompletedBeforeDomains(
        expected: Set<ModelDomain>,
        actual: Set<ModelDomain>
    )
    case unknownTarget(WebInspectorTarget.ID)
    case targetScopeMismatch(WebInspectorTarget.ID)
    case invalidTargetLifecycle
    case currentPageTargetWasDestroyed(WebInspectorTarget.ID)
    case navigationEpochDidNotAdvanceExactlyOnce(
        targetID: WebInspectorTarget.ID,
        previous: ModelNavigationEpoch,
        proposed: ModelNavigationEpoch
    )
    case invalidDOMBinding(WebInspectorTarget.ID)
    case DOMEventBeforeBootstrap(WebInspectorTarget.ID)
    case CSSEventBeforeBootstrap
    case DOMInvalidationDidNotAdvanceExactlyOnce(
        targetID: WebInspectorTarget.ID,
        previous: ModelDOMBindingEpoch,
        proposed: ModelDOMBindingEpoch
    )
    case runtimeBindingMismatch(WebInspectorTarget.ID)
    case consoleBindingMismatch(WebInspectorTarget.ID)
    case networkMappedFrameTargetUnavailable(
        frameID: FrameID,
        targetID: WebInspectorTarget.ID
    )
    case operationalRuntimeEventWithoutRuntimeProjection
    case inspectorSelectionOutsideCurrentDocument
}

package enum WebInspectorCanonicalModelStoreError: Error, Equatable, Sendable {
    case protocolViolation(WebInspectorCanonicalFeedProtocolViolation)
    case networkProtocol(CanonicalNetworkProtocolViolation)
    case networkStore(CanonicalNetworkStoreError)
    case DOM(WebInspectorCanonicalDOMError)
    case CSS(WebInspectorCanonicalCSSError)
    case consoleRuntimeProtocol(CanonicalConsoleRuntimeProtocolViolation)
    case consoleRuntimeStore(CanonicalConsoleRuntimeStoreError)
}

package enum WebInspectorCanonicalSnapshotReason: Hashable, Sendable {
    case initial
    case reset
    case onDemandRebase
}

package struct WebInspectorCanonicalFeedBindingSnapshot: Equatable, Sendable {
    package let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    package let pageGeneration: WebInspectorPage.Generation
    package let lastSequence: UInt64?
    package let currentPageID: WebInspectorTarget.ID?
    package let targets: [ModelTargetState]
    package let readyDOMTargetIDs: Set<WebInspectorTarget.ID>
    package let completedDomains: Set<ModelDomain>
    package let isCSSReady: Bool
    package let isSynchronized: Bool
}

package struct WebInspectorCanonicalModelSnapshot: Equatable, Sendable {
    package let binding: WebInspectorCanonicalFeedBindingSnapshot?
    package let network: CanonicalNetworkSnapshot?
    package let DOM: WebInspectorCanonicalDOMSnapshot?
    package let CSS: WebInspectorCanonicalCSSSnapshot?
    package let consoleRuntime: CanonicalConsoleRuntimeSnapshot?
}

package enum WebInspectorCanonicalFeedChange: Equatable, Sendable {
    case reset(
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation
    )
    case detached(
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation
    )
    case targetSnapshot(through: UInt64, snapshot: ModelTargetSnapshot)
    case targetCreated(ModelTarget)
    case targetRemoved(WebInspectorTarget.ID)
    case provisionalTargetCommitted(
        oldTargetID: WebInspectorTarget.ID,
        newTarget: ModelTarget
    )
    case frameNavigated(
        frameID: FrameID,
        deliveryTargetID: WebInspectorTarget.ID,
        navigationEpoch: ModelNavigationEpoch
    )
    case frameDetached(
        frameID: FrameID,
        deliveryTargetID: WebInspectorTarget.ID
    )
    case DOMDocumentInvalidated(
        targetID: WebInspectorTarget.ID,
        epoch: ModelDOMBindingEpoch
    )
    case replayComplete(domain: ModelDomain, through: UInt64)
    case bootstrapSnapshot(domain: ModelDomain, through: UInt64)
    case bootstrapComplete(domain: ModelDomain, through: UInt64)
    case synchronizationComplete(through: UInt64)
}

package enum WebInspectorCanonicalModelAction: Equatable, Sendable {
    /// A validated selection request. The future Container Core decides
    /// whether its current element-picker lease authorizes the command.
    case inspectRemoteObject(
        scope: ModelEventScope,
        objectID: Runtime.RemoteObject.ID?
    )
}

package struct WebInspectorCanonicalModelTransaction: Equatable, Sendable {
    package var feedChanges: [WebInspectorCanonicalFeedChange] = []
    package var network: CanonicalNetworkTransaction?
    package var DOM: WebInspectorCanonicalDOMTransaction?
    package var CSS: WebInspectorCanonicalCSSTransaction?
    package var consoleRuntime: CanonicalConsoleRuntimeTransaction?
    package var actions: [WebInspectorCanonicalModelAction] = []
    package var resetSnapshot: WebInspectorCanonicalModelSnapshot? = nil

    package var isEmpty: Bool {
        feedChanges.isEmpty
            && (network.map {
                $0.requestChanges.isEmpty && $0.entryChanges.isEmpty
            } ?? true)
            && (DOM?.isEmpty ?? true)
            && (CSS?.isEmpty ?? true)
            && (consoleRuntime?.isEmpty ?? true)
            && actions.isEmpty
            && resetSnapshot == nil
    }
}

package struct WebInspectorCanonicalModelStorePerformanceCounters: Equatable, Sendable {
    package fileprivate(set) var reducedFeedRecordCount = 0
    package fileprivate(set) var fullSnapshotBuildCount = 0
    package fileprivate(set) var initialSnapshotBuildCount = 0
    package fileprivate(set) var resetSnapshotBuildCount = 0
    package fileprivate(set) var onDemandSnapshotBuildCount = 0
    package fileprivate(set) var fullSnapshotRecordVisitCount = 0
    package fileprivate(set) var unrelatedRecordScanCount = 0
    package fileprivate(set) var bindingEpochMapMutationCount = 0
}

/// Pure, ordered canonical state intended to be owned by exactly one
/// `WebInspectorModelContainerCore` actor.
///
/// The value contains no actor, Task, Observable identity, Proxy handle, UI
/// selection, or query registration. A feed record either commits its binding
/// and every affected domain transaction together or leaves the entire store
/// unchanged.
package struct WebInspectorCanonicalModelStore: Sendable {
    private struct ResetScope: Equatable, Sendable {
        let attachmentGeneration: WebInspectorContainerAttachmentGeneration
        let pageGeneration: WebInspectorPage.Generation
    }

    private enum DOMPhase: Equatable, Sendable {
        case awaiting
        case ready
    }

    private struct DOMAuthority: Equatable, Sendable {
        var scope: ModelEventScope
        var phase: DOMPhase
        var isEstablishedInReducer: Bool
    }

    private struct BindingState: Equatable, Sendable {
        var attachmentGeneration: WebInspectorContainerAttachmentGeneration
        var pageGeneration: WebInspectorPage.Generation
        var lastSequence: UInt64?
        var targetSnapshotWasApplied: Bool
        var currentPageID: WebInspectorTarget.ID?
        var targets: [WebInspectorTarget.ID: ModelTarget]
        var navigationEpochs: [WebInspectorTarget.ID: ModelNavigationEpoch]
        var DOMAuthorities: [WebInspectorTarget.ID: DOMAuthority]
        var runtimeBindingEpochs: [WebInspectorTarget.ID: ModelRuntimeBindingEpoch]
        var consoleBindingEpochs: [WebInspectorTarget.ID: ModelConsoleBindingEpoch]
        var bootstrapSnapshotThrough: [ModelDomain: UInt64]
        var bootstrapCompletionThrough: [ModelDomain: UInt64]
        var completedDomains: Set<ModelDomain>
        var isCSSReady: Bool
        var establishedCSSRoutes: Set<WebInspectorDOMTargetRouteStorage>
        var didSynchronize: Bool
        var epochMapMutationCount: Int
    }

    package let storeID: WebInspectorContainerStoreID
    package let configuredDomains: Set<ModelDomain>

    private var binding: BindingState?
    private var lastResetScope: ResetScope?
    private var networkStore: CanonicalNetworkStore
    private var DOMReducer: WebInspectorCanonicalDOMReducer?
    private var CSSReducer: WebInspectorCanonicalCSSReducer?
    private var consoleRuntimeStore: CanonicalConsoleRuntimeStore

    package private(set) var performanceCounters =
        WebInspectorCanonicalModelStorePerformanceCounters()

    package init(
        storeID: WebInspectorContainerStoreID = WebInspectorContainerStoreID(),
        configuredDomains: Set<ModelDomain>
    ) {
        self.storeID = storeID
        var normalizedDomains = configuredDomains
        if normalizedDomains.contains(.css) {
            normalizedDomains.insert(.dom)
        }
        self.configuredDomains = normalizedDomains
        binding = nil
        lastResetScope = nil
        networkStore = CanonicalNetworkStore(storeID: storeID)
        DOMReducer = nil
        CSSReducer = nil
        consoleRuntimeStore = CanonicalConsoleRuntimeStore(
            storeID: storeID,
            projectsRuntimeContexts: configuredDomains.contains(.runtime)
        )
    }

    package var bindingSnapshot: WebInspectorCanonicalFeedBindingSnapshot? {
        binding.map(makeBindingSnapshot)
    }

    package func networkRequestID(
        forRawRequestID rawID: Network.Request.ID
    ) -> CanonicalNetworkRequestIDStorage? {
        guard configuredDomains.contains(.network) else {
            return nil
        }
        return networkStore.requestID(forRawRequestID: rawID)
    }

    package func networkRequest(
        for id: CanonicalNetworkRequestIDStorage
    ) -> CanonicalNetworkRequestRecord? {
        networkStore.request(for: id)
    }

    package func runtimeContext(
        for id: CanonicalRuntimeContextIDStorage
    ) -> CanonicalRuntimeContextRecord? {
        consoleRuntimeStore.runtimeContext(for: id)
    }

    package func consoleMessage(
        for id: CanonicalConsoleMessageIDStorage
    ) -> CanonicalConsoleMessageRecord? {
        consoleRuntimeStore.consoleMessage(for: id)
    }

    #if DEBUG
        package var networkPerformanceCountersForTesting: CanonicalNetworkStore.PerformanceCounters {
            networkStore.performanceCountersForTesting
        }

        package var DOMPerformanceCountersForTesting: WebInspectorCanonicalDOMPerformanceCounters? {
            DOMReducer?.performanceCounters
        }

        package var CSSPerformanceCountersForTesting: WebInspectorCanonicalCSSPerformanceCounters? {
            CSSReducer?.performanceCounters
        }

        package var consoleRuntimePerformanceCountersForTesting: CanonicalConsoleRuntimeStore.PerformanceCounters {
            consoleRuntimeStore.performanceCounters
        }
    #endif

    /// Builds the complete canonical state only at an initial/reset boundary
    /// or when a slow subscriber actually requests an owner-atomic rebase.
    package mutating func snapshot(
        reason: WebInspectorCanonicalSnapshotReason
    ) -> WebInspectorCanonicalModelSnapshot {
        let network =
            configuredDomains.contains(.network)
            ? networkStore.snapshot
            : nil
        let DOM =
            configuredDomains.contains(.dom)
            ? DOMReducer?.snapshot()
                ?? WebInspectorCanonicalDOMSnapshot(
                    recordsByID: [:],
                    parentByNodeID: [:],
                    rootByDocumentScope: [:]
                )
            : nil
        let CSS =
            configuredDomains.contains(.css)
            ? CSSReducer?.snapshot()
                ?? WebInspectorCanonicalCSSSnapshot(
                    recordsByID: [:],
                    cascadeRevisionByScope: [:]
                )
            : nil
        let consoleRuntime =
            configuredDomains.contains(.console)
                || configuredDomains.contains(.runtime)
            ? consoleRuntimeStore.snapshot()
            : nil

        performanceCounters.fullSnapshotBuildCount += 1
        switch reason {
        case .initial:
            performanceCounters.initialSnapshotBuildCount += 1
        case .reset:
            performanceCounters.resetSnapshotBuildCount += 1
        case .onDemandRebase:
            performanceCounters.onDemandSnapshotBuildCount += 1
        }
        performanceCounters.fullSnapshotRecordVisitCount +=
            (network?.requests.count ?? 0)
            + (network?.entries.count ?? 0)
            + (DOM?.records.count ?? 0)
            + (CSS?.recordsByID.count ?? 0)
            + (consoleRuntime?.runtimeContexts.count ?? 0)
            + (consoleRuntime?.consoleMessages.count ?? 0)

        return WebInspectorCanonicalModelSnapshot(
            binding: bindingSnapshot,
            network: network,
            DOM: DOM,
            CSS: CSS,
            consoleRuntime: consoleRuntime
        )
    }

    /// Applies one record from the single ordered ProxyKit model feed.
    /// `attachmentGeneration` is allocated by the Container and must never be
    /// reused, including for failed or superseded native attachment attempts.
    @discardableResult
    package mutating func reduce(
        _ record: ConnectionModelFeedRecord,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration
    ) throws -> WebInspectorCanonicalModelTransaction {
        do {
            let priorEpochMapMutationCount = binding?.epochMapMutationCount ?? 0
            let transaction = try reduceValidated(
                record,
                attachmentGeneration: attachmentGeneration
            )
            performanceCounters.reducedFeedRecordCount += 1
            if let currentEpochMapMutationCount = binding?.epochMapMutationCount,
                currentEpochMapMutationCount >= priorEpochMapMutationCount
            {
                performanceCounters.bindingEpochMapMutationCount +=
                    currentEpochMapMutationCount - priorEpochMapMutationCount
            }
            return transaction
        } catch let error as WebInspectorCanonicalModelStoreError {
            throw error
        } catch let error as CanonicalNetworkProtocolViolation {
            throw WebInspectorCanonicalModelStoreError.networkProtocol(error)
        } catch let error as CanonicalNetworkStoreError {
            throw WebInspectorCanonicalModelStoreError.networkStore(error)
        } catch let error as WebInspectorCanonicalDOMError {
            throw WebInspectorCanonicalModelStoreError.DOM(error)
        } catch let error as WebInspectorCanonicalCSSError {
            throw WebInspectorCanonicalModelStoreError.CSS(error)
        } catch let error as CanonicalConsoleRuntimeProtocolViolation {
            throw WebInspectorCanonicalModelStoreError.consoleRuntimeProtocol(error)
        } catch let error as CanonicalConsoleRuntimeStoreError {
            throw WebInspectorCanonicalModelStoreError.consoleRuntimeStore(error)
        } catch {
            preconditionFailure(
                "A canonical domain reducer threw an undeclared error: \(error)"
            )
        }
    }

    /// Clears one adopted attachment without terminating the stable store.
    ///
    /// The returned transaction is the complete detach reset delivered to
    /// existing context subscriptions. A later attachment must still advance
    /// from the retained reset scope, even though the public binding is nil.
    @discardableResult
    package mutating func clearForDetach() -> WebInspectorCanonicalModelTransaction {
        guard let current = binding else {
            return WebInspectorCanonicalModelTransaction()
        }

        let networkTransaction =
            configuredDomains.contains(.network)
            ? networkStore.clear()
            : nil
        let consoleRuntimeTransaction =
            configuredDomains.contains(.console)
                || configuredDomains.contains(.runtime)
            ? consoleRuntimeStore.clearForDetach()
            : nil
        let DOMTransaction = DOMReducer?.reset()
        let CSSTransaction = CSSReducer?.reset()
        binding = nil

        var transaction = WebInspectorCanonicalModelTransaction(
            feedChanges: [
                .detached(
                    attachmentGeneration: current.attachmentGeneration,
                    pageGeneration: current.pageGeneration
                )
            ],
            network: networkTransaction,
            DOM: DOMTransaction,
            CSS: CSSTransaction,
            consoleRuntime: consoleRuntimeTransaction
        )
        transaction.resetSnapshot = snapshot(reason: .reset)
        return transaction
    }

    /// Replaces every semantic store after terminal publication has finished.
    /// Unlike detach, terminal close has no subscriber that needs a reset
    /// transaction, retained capacity, tombstones, or a reset snapshot.
    package mutating func releaseSemanticStorageForClose() {
        let performanceCounters = performanceCounters
        self = WebInspectorCanonicalModelStore(
            storeID: storeID,
            configuredDomains: configuredDomains
        )
        self.performanceCounters = performanceCounters
    }
}

private extension WebInspectorCanonicalModelStore {
    var requiresRuntimeBinding: Bool {
        configuredDomains.contains(.runtime)
            || configuredDomains.contains(.console)
    }

    private func makeBindingSnapshot(
        _ binding: BindingState
    ) -> WebInspectorCanonicalFeedBindingSnapshot {
        let targets = binding.targets.values.sorted {
            $0.id.rawValue < $1.id.rawValue
        }.map { target in
            ModelTargetState(
                target: target,
                navigationEpoch: binding.navigationEpochs[target.id]!,
                domBindingEpoch: binding.DOMAuthorities[target.id]?.scope.domBindingEpoch,
                runtimeBindingEpoch: binding.runtimeBindingEpochs[target.id],
                consoleBindingEpoch: binding.consoleBindingEpochs[target.id]
            )
        }
        return WebInspectorCanonicalFeedBindingSnapshot(
            attachmentGeneration: binding.attachmentGeneration,
            pageGeneration: binding.pageGeneration,
            lastSequence: binding.lastSequence,
            currentPageID: binding.currentPageID,
            targets: targets,
            readyDOMTargetIDs: Set(
                binding.DOMAuthorities.compactMap { id, authority in
                    authority.phase == .ready ? id : nil
                }
            ),
            completedDomains: binding.completedDomains,
            isCSSReady: binding.isCSSReady,
            isSynchronized: binding.didSynchronize
        )
    }

    mutating func reduceValidated(
        _ record: ConnectionModelFeedRecord,
        attachmentGeneration: WebInspectorContainerAttachmentGeneration
    ) throws -> WebInspectorCanonicalModelTransaction {
        if case let .reset(pageGeneration) = record {
            return try reset(
                attachmentGeneration: attachmentGeneration,
                pageGeneration: pageGeneration
            )
        }

        guard let current = binding else {
            throw protocolViolation(.recordBeforeReset)
        }
        guard current.attachmentGeneration == attachmentGeneration else {
            throw protocolViolation(
                .staleAttachment(
                    expected: current.attachmentGeneration,
                    actual: attachmentGeneration
                )
            )
        }

        switch record {
        case .reset:
            preconditionFailure("Reset records are handled before attachment validation.")

        case let .targetSnapshot(generation, through, snapshot):
            var next = current
            try requireGeneration(generation, in: next)
            guard !next.targetSnapshotWasApplied else {
                throw protocolViolation(.duplicateTargetSnapshot)
            }
            try acceptWatermark(through, in: &next)
            try install(snapshot, in: &next)
            binding = next
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.targetSnapshot(through: through, snapshot: snapshot)]
            )

        case let .domDocumentInvalidated(sequence, scope):
            return try reduceDOMInvalidation(
                sequence: sequence,
                scope: scope,
                binding: current
            )

        case let .event(sequence, scope, payload):
            var next = current
            try requireGeneration(scope.generation, in: next)
            try acceptSequence(sequence, in: &next)
            guard next.targetSnapshotWasApplied else {
                throw protocolViolation(.eventBeforeTargetSnapshot)
            }
            let transaction = try reduce(
                payload,
                scope: scope,
                binding: &next
            )
            binding = next
            if transaction.feedChanges.isEmpty,
                case .target = payload
            {
                preconditionFailure("A target lifecycle reduction lost its typed feed change.")
            }
            return transaction

        case let .replayComplete(generation, domain, through):
            var next = current
            try requireGeneration(generation, in: next)
            guard next.targetSnapshotWasApplied else {
                throw protocolViolation(.eventBeforeTargetSnapshot)
            }
            guard configuredDomains.contains(domain) else {
                throw protocolViolation(.unconfiguredDomain(domain))
            }
            guard Self.replayDomains.contains(domain) else {
                throw protocolViolation(.invalidReplayDomain(domain))
            }
            guard !next.completedDomains.contains(domain) else {
                throw protocolViolation(.duplicateDomainBoundary(domain))
            }
            try acceptWatermark(through, in: &next)
            next.completedDomains.insert(domain)
            binding = next
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.replayComplete(domain: domain, through: through)]
            )

        case let .bootstrapSnapshot(generation, domain, sequence, payload):
            return try reduceBootstrapSnapshot(
                generation: generation,
                domain: domain,
                sequence: sequence,
                payload: payload,
                binding: current
            )

        case let .bootstrapComplete(generation, domain, through):
            var next = current
            try requireGeneration(generation, in: next)
            guard Self.bootstrapDomains.contains(domain) else {
                throw protocolViolation(.invalidBootstrapDomain(domain))
            }
            guard configuredDomains.contains(domain) else {
                throw protocolViolation(.unconfiguredDomain(domain))
            }
            try acceptWatermark(through, in: &next)
            try requireBootstrapAuthority(domain, in: next)
            if let previous = next.bootstrapCompletionThrough[domain],
                through <= previous
            {
                throw protocolViolation(.duplicateDomainBoundary(domain))
            }
            next.bootstrapCompletionThrough[domain] = through
            if !next.didSynchronize {
                next.completedDomains.insert(domain)
            }
            binding = next
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.bootstrapComplete(domain: domain, through: through)]
            )

        case let .synchronizationComplete(generation, through):
            var next = current
            try requireGeneration(generation, in: next)
            guard next.targetSnapshotWasApplied else {
                throw protocolViolation(.eventBeforeTargetSnapshot)
            }
            guard !next.didSynchronize else {
                throw protocolViolation(.synchronizationCompletedTwice)
            }
            guard next.completedDomains == configuredDomains else {
                throw protocolViolation(
                    .synchronizationCompletedBeforeDomains(
                        expected: configuredDomains,
                        actual: next.completedDomains
                    )
                )
            }
            try acceptWatermark(through, in: &next)
            next.didSynchronize = true
            binding = next
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.synchronizationComplete(through: through)]
            )
        }
    }

    static let replayDomains: Set<ModelDomain> = [
        .network, .console, .runtime,
    ]

    static let bootstrapDomains: Set<ModelDomain> = [.dom, .css]

    func protocolViolation(
        _ violation: WebInspectorCanonicalFeedProtocolViolation
    ) -> WebInspectorCanonicalModelStoreError {
        .protocolViolation(violation)
    }
}

private extension WebInspectorCanonicalModelStore {
    mutating func reset(
        attachmentGeneration: WebInspectorContainerAttachmentGeneration,
        pageGeneration: WebInspectorPage.Generation
    ) throws -> WebInspectorCanonicalModelTransaction {
        if let current = lastResetScope {
            let isValid: Bool
            if binding == nil {
                isValid = attachmentGeneration > current.attachmentGeneration
            } else if attachmentGeneration == current.attachmentGeneration {
                isValid = pageGeneration.rawValue > current.pageGeneration.rawValue
            } else {
                isValid = attachmentGeneration > current.attachmentGeneration
            }
            guard isValid else {
                throw protocolViolation(
                    .nonmonotonicReset(
                        currentAttachment: current.attachmentGeneration,
                        currentPage: current.pageGeneration,
                        proposedAttachment: attachmentGeneration,
                        proposedPage: pageGeneration
                    )
                )
            }
        }

        var nextNetwork = networkStore
        var nextConsoleRuntime = consoleRuntimeStore
        var nextDOM = DOMReducer
        var nextCSS = CSSReducer

        let networkTransaction =
            configuredDomains.contains(.network)
            ? try nextNetwork.reset(
                attachmentGeneration: attachmentGeneration,
                pageGeneration: pageGeneration
            )
            : nil
        let consoleRuntimeTransaction =
            configuredDomains.contains(.console)
                || configuredDomains.contains(.runtime)
            ? try nextConsoleRuntime.reset(
                attachmentGeneration: attachmentGeneration,
                pageGeneration: pageGeneration
            )
            : nil

        let DOMTransaction = nextDOM?.reset()
        let CSSTransaction = nextCSS?.reset()
        nextDOM =
            configuredDomains.contains(.dom)
            ? WebInspectorCanonicalDOMReducer(
                storeID: storeID,
                attachmentGeneration: attachmentGeneration
            )
            : nil
        nextCSS =
            configuredDomains.contains(.css)
            ? WebInspectorCanonicalCSSReducer(
                storeID: storeID,
                attachmentGeneration: attachmentGeneration
            )
            : nil

        networkStore = nextNetwork
        consoleRuntimeStore = nextConsoleRuntime
        DOMReducer = nextDOM
        CSSReducer = nextCSS
        lastResetScope = ResetScope(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration
        )
        binding = BindingState(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration,
            lastSequence: nil,
            targetSnapshotWasApplied: false,
            currentPageID: nil,
            targets: [:],
            navigationEpochs: [:],
            DOMAuthorities: [:],
            runtimeBindingEpochs: [:],
            consoleBindingEpochs: [:],
            bootstrapSnapshotThrough: [:],
            bootstrapCompletionThrough: [:],
            completedDomains: [],
            isCSSReady: false,
            establishedCSSRoutes: [],
            didSynchronize: false,
            epochMapMutationCount: 0
        )

        return WebInspectorCanonicalModelTransaction(
            feedChanges: [
                .reset(
                    attachmentGeneration: attachmentGeneration,
                    pageGeneration: pageGeneration
                )
            ],
            network: networkTransaction,
            DOM: DOMTransaction,
            CSS: CSSTransaction,
            consoleRuntime: consoleRuntimeTransaction
        )
    }

    private func requireGeneration(
        _ generation: WebInspectorPage.Generation,
        in binding: BindingState
    ) throws {
        guard binding.pageGeneration == generation else {
            throw protocolViolation(
                .generationMismatch(
                    expected: binding.pageGeneration,
                    actual: generation
                )
            )
        }
    }

    private func acceptSequence(
        _ sequence: UInt64,
        in binding: inout BindingState
    ) throws {
        guard binding.lastSequence.map({ sequence > $0 }) ?? true else {
            throw protocolViolation(
                .sequenceDidNotAdvance(
                    previous: binding.lastSequence,
                    proposed: sequence
                )
            )
        }
        binding.lastSequence = sequence
    }

    private func acceptWatermark(
        _ sequence: UInt64,
        in binding: inout BindingState
    ) throws {
        guard binding.lastSequence.map({ sequence >= $0 }) ?? true else {
            throw protocolViolation(
                .watermarkMovedBackward(
                    previous: binding.lastSequence,
                    proposed: sequence
                )
            )
        }
        binding.lastSequence = sequence
    }

    private func install(
        _ snapshot: ModelTargetSnapshot,
        in binding: inout BindingState
    ) throws {
        let targetIDs = snapshot.targets.map(\.target.id)
        guard Set(targetIDs).count == targetIDs.count,
            snapshot.targets.contains(where: {
                $0.target.id == snapshot.currentPageID
            }),
            snapshot.targets.allSatisfy(isValidTargetState)
        else {
            throw protocolViolation(.invalidTargetSnapshot)
        }

        binding.targetSnapshotWasApplied = true
        binding.currentPageID = snapshot.currentPageID
        binding.targets = Dictionary(
            uniqueKeysWithValues: snapshot.targets.map {
                ($0.target.id, $0.target)
            }
        )
        binding.navigationEpochs = Dictionary(
            uniqueKeysWithValues: snapshot.targets.map {
                ($0.target.id, $0.navigationEpoch)
            }
        )
        if configuredDomains.contains(.dom) {
            binding.DOMAuthorities = Dictionary(
                uniqueKeysWithValues: snapshot.targets.map { state in
                    let scope = ModelEventScope(
                        generation: binding.pageGeneration,
                        target: state.target,
                        agentTarget: state.target,
                        navigationEpoch: state.navigationEpoch,
                        domBindingEpoch: state.domBindingEpoch,
                        runtimeBindingEpoch: state.runtimeBindingEpoch,
                        consoleBindingEpoch: state.consoleBindingEpoch
                    )
                    return (
                        state.target.id,
                        DOMAuthority(
                            scope: scope,
                            phase: .awaiting,
                            isEstablishedInReducer: false
                        )
                    )
                }
            )
        }
        if requiresRuntimeBinding {
            binding.runtimeBindingEpochs = Dictionary(
                uniqueKeysWithValues: snapshot.targets.map {
                    ($0.target.id, $0.runtimeBindingEpoch!)
                }
            )
        }
        if configuredDomains.contains(.console) {
            binding.consoleBindingEpochs = Dictionary(
                uniqueKeysWithValues: snapshot.targets.map {
                    ($0.target.id, $0.consoleBindingEpoch!)
                }
            )
        }
    }

    func isValidTargetState(_ state: ModelTargetState) -> Bool {
        let validDOM =
            configuredDomains.contains(.dom)
            ? state.domBindingEpoch != nil
            : state.domBindingEpoch == nil
        let validRuntime =
            requiresRuntimeBinding
            ? state.runtimeBindingEpoch != nil
            : state.runtimeBindingEpoch == nil
        let validConsole =
            configuredDomains.contains(.console)
            ? state.consoleBindingEpoch != nil
            : state.consoleBindingEpoch == nil
        return validDOM && validRuntime && validConsole
    }
}

private extension WebInspectorCanonicalModelStore {
    private mutating func reduceDOMInvalidation(
        sequence: UInt64,
        scope: ModelEventScope,
        binding current: BindingState
    ) throws -> WebInspectorCanonicalModelTransaction {
        guard configuredDomains.contains(.dom) else {
            throw protocolViolation(.unconfiguredDomain(.dom))
        }
        var next = current
        try requireGeneration(scope.generation, in: next)
        try acceptSequence(sequence, in: &next)
        try validateRegisteredTargets(scope, in: next)
        try validateNavigation(scope, in: next)
        _ = try acceptAgentBindings(scope, in: &next)

        guard let previous = next.DOMAuthorities[scope.target.id],
            let previousEpoch = previous.scope.domBindingEpoch,
            let proposedEpoch = scope.domBindingEpoch,
            previousEpoch.rawValue != UInt64.max,
            proposedEpoch.rawValue == previousEpoch.rawValue + 1
        else {
            let previousEpoch =
                next.DOMAuthorities[scope.target.id]?
                .scope.domBindingEpoch ?? ModelDOMBindingEpoch(rawValue: 0)
            let proposedEpoch =
                scope.domBindingEpoch
                ?? ModelDOMBindingEpoch(rawValue: 0)
            throw protocolViolation(
                .DOMInvalidationDidNotAdvanceExactlyOnce(
                    targetID: scope.target.id,
                    previous: previousEpoch,
                    proposed: proposedEpoch
                )
            )
        }

        var nextDOM = DOMReducer
        var nextCSS = CSSReducer
        var DOMTransaction: WebInspectorCanonicalDOMTransaction?
        var CSSTransaction: WebInspectorCanonicalCSSTransaction?
        if previous.isEstablishedInReducer {
            guard var reducer = nextDOM else {
                preconditionFailure("Configured DOM reduction lost its reducer.")
            }
            DOMTransaction = try reducer.invalidateDocument(
                WebInspectorCanonicalDOMEventScope(modelScope: scope)
            )
            nextDOM = reducer
        }
        let route = WebInspectorDOMTargetRouteStorage(
            semanticTargetID: scope.target.id,
            agentTargetID: scope.agentTarget.id
        )
        if configuredDomains.contains(.css),
            next.establishedCSSRoutes.contains(route)
        {
            guard var reducer = nextCSS else {
                preconditionFailure("Configured CSS reduction lost its reducer.")
            }
            CSSTransaction = try reducer.invalidateDocument(
                WebInspectorCanonicalDOMEventScope(modelScope: scope)
            )
            nextCSS = reducer
        }

        next.DOMAuthorities[scope.target.id] = DOMAuthority(
            scope: scope,
            phase: .awaiting,
            isEstablishedInReducer: previous.isEstablishedInReducer
        )
        if configuredDomains.contains(.css) {
            next.isCSSReady = false
        }
        DOMReducer = nextDOM
        CSSReducer = nextCSS
        binding = next
        return WebInspectorCanonicalModelTransaction(
            feedChanges: [
                .DOMDocumentInvalidated(
                    targetID: scope.target.id,
                    epoch: proposedEpoch
                )
            ],
            DOM: DOMTransaction,
            CSS: CSSTransaction
        )
    }

    private mutating func reduceBootstrapSnapshot(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        sequence: UInt64,
        payload: ModelBootstrapSnapshot,
        binding current: BindingState
    ) throws -> WebInspectorCanonicalModelTransaction {
        var next = current
        try requireGeneration(generation, in: next)
        guard configuredDomains.contains(domain) else {
            throw protocolViolation(.unconfiguredDomain(domain))
        }
        guard Self.bootstrapDomains.contains(domain) else {
            throw protocolViolation(.invalidBootstrapDomain(domain))
        }
        try acceptWatermark(sequence, in: &next)
        if let previous = next.bootstrapSnapshotThrough[domain],
            sequence <= previous
        {
            throw protocolViolation(.duplicateDomainBoundary(domain))
        }

        switch (domain, payload) {
        case let (.dom, .domDocument(scope, root)):
            try requireGeneration(scope.generation, in: next)
            try validateModelScope(scope, in: &next, requireDOMReady: false)
            guard let authority = next.DOMAuthorities[scope.target.id],
                authority.phase == .awaiting,
                authority.scope.domBindingEpoch == scope.domBindingEpoch
            else {
                throw protocolViolation(.invalidDOMBinding(scope.target.id))
            }
            guard var reducer = DOMReducer else {
                preconditionFailure("Configured DOM bootstrap lost its reducer.")
            }
            let transaction = try reducer.bootstrap(
                scope: WebInspectorCanonicalDOMEventScope(modelScope: scope),
                root: root
            )
            next.DOMAuthorities[scope.target.id] = DOMAuthority(
                scope: scope,
                phase: .ready,
                isEstablishedInReducer: true
            )
            next.bootstrapSnapshotThrough[domain] = sequence
            DOMReducer = reducer
            binding = next
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.bootstrapSnapshot(domain: domain, through: sequence)],
                DOM: transaction
            )

        case let (.css, .cssStyleSheets(styleSheets)):
            guard next.DOMAuthorities.values.allSatisfy({ $0.phase == .ready }) else {
                throw protocolViolation(.domainCompletedBeforeAuthority(.dom))
            }
            for styleSheet in styleSheets {
                try requireGeneration(styleSheet.scope.generation, in: next)
                try validateModelScope(
                    styleSheet.scope,
                    in: &next,
                    requireDOMReady: true
                )
            }
            let eventScopes = next.DOMAuthorities.values
                .map(\.scope)
                .sorted { lhs, rhs in
                    if lhs.target.id != rhs.target.id {
                        return lhs.target.id.rawValue < rhs.target.id.rawValue
                    }
                    return lhs.agentTarget.id.rawValue < rhs.agentTarget.id.rawValue
                }
                .map(WebInspectorCanonicalDOMEventScope.init(modelScope:))
            guard var reducer = CSSReducer else {
                preconditionFailure("Configured CSS bootstrap lost its reducer.")
            }
            let transaction = try reducer.bootstrap(
                scopes: eventScopes,
                styleSheets: styleSheets.map {
                    WebInspectorCanonicalCSSStyleSheetSnapshotRecord(
                        scope: WebInspectorCanonicalDOMEventScope(
                            modelScope: $0.scope
                        ),
                        header: $0.header
                    )
                }
            )
            next.bootstrapSnapshotThrough[domain] = sequence
            next.isCSSReady = true
            next.establishedCSSRoutes = Set(
                eventScopes.map { eventScope in
                    WebInspectorDOMTargetRouteStorage(
                        semanticTargetID: eventScope.semanticTargetID,
                        agentTargetID: eventScope.agentTargetID
                    )
                }
            )
            CSSReducer = reducer
            binding = next
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.bootstrapSnapshot(domain: domain, through: sequence)],
                CSS: transaction
            )

        case (.dom, .cssStyleSheets), (.css, .domDocument),
            (.network, _), (.console, _), (.runtime, _):
            throw protocolViolation(.bootstrapPayloadMismatch(domain))
        }
    }

    private func requireBootstrapAuthority(
        _ domain: ModelDomain,
        in binding: BindingState
    ) throws {
        switch domain {
        case .dom:
            guard binding.DOMAuthorities.values.allSatisfy({ $0.phase == .ready }) else {
                throw protocolViolation(.domainCompletedBeforeAuthority(domain))
            }
        case .css:
            guard binding.isCSSReady,
                binding.bootstrapSnapshotThrough[domain] != nil
            else {
                throw protocolViolation(.domainCompletedBeforeAuthority(domain))
            }
        case .network, .console, .runtime:
            throw protocolViolation(.invalidBootstrapDomain(domain))
        }
    }
}

private extension WebInspectorCanonicalModelStore {
    private mutating func reduce(
        _ payload: ModelProtocolEvent,
        scope: ModelEventScope,
        binding: inout BindingState
    ) throws -> WebInspectorCanonicalModelTransaction {
        switch payload {
        case let .target(event):
            return try reduceTargetLifecycle(
                event,
                scope: scope,
                binding: &binding
            )

        case let .dom(event):
            guard configuredDomains.contains(.dom) else {
                throw protocolViolation(.unconfiguredDomain(.dom))
            }
            try validateModelScope(scope, in: &binding, requireDOMReady: true)
            if case .documentUpdated = event {
                throw WebInspectorCanonicalModelStoreError.DOM(
                    .documentUpdatedRequiresInvalidationBoundary
                )
            }
            guard var reducer = DOMReducer else {
                preconditionFailure("Configured DOM event lost its reducer.")
            }
            let transaction = try reducer.apply(
                scope: WebInspectorCanonicalDOMEventScope(modelScope: scope),
                event: event
            )
            DOMReducer = reducer
            return WebInspectorCanonicalModelTransaction(DOM: transaction)

        case let .css(event):
            guard configuredDomains.contains(.css) else {
                throw protocolViolation(.unconfiguredDomain(.css))
            }
            try validateModelScope(scope, in: &binding, requireDOMReady: true)
            guard binding.isCSSReady else {
                throw protocolViolation(.CSSEventBeforeBootstrap)
            }
            guard var reducer = CSSReducer else {
                preconditionFailure("Configured CSS event lost its reducer.")
            }
            let transaction = try reducer.apply(
                scope: WebInspectorCanonicalDOMEventScope(modelScope: scope),
                event: event
            )
            CSSReducer = reducer
            return WebInspectorCanonicalModelTransaction(CSS: transaction)

        case let .network(event):
            guard configuredDomains.contains(.network) else {
                throw protocolViolation(.unconfiguredDomain(.network))
            }
            try validateModelScope(scope, in: &binding, requireDOMReady: false)
            return try reduceNetwork(
                event,
                scope: scope,
                binding: binding,
                origin: binding.completedDomains.contains(.network)
                    ? .live
                    : .enableReplay
            )

        case let .console(event):
            guard configuredDomains.contains(.console) else {
                throw protocolViolation(.unconfiguredDomain(.console))
            }
            let mustAdvance: Bool
            if case .messagesCleared = event {
                mustAdvance = true
            } else {
                mustAdvance = false
            }
            try validateModelScope(
                scope,
                in: &binding,
                consoleMustAdvance: mustAdvance
            )
            let resolution = consoleNetworkResolution(for: event)
            let transaction = try consoleRuntimeStore.reduceConsole(
                event,
                scope: scope,
                networkRequestResolution: resolution
            )
            return WebInspectorCanonicalModelTransaction(
                consoleRuntime: transaction
            )

        case let .runtime(event):
            let clears: Bool
            if case .executionContextsCleared = event {
                clears = true
            } else {
                clears = false
            }
            guard
                configuredDomains.contains(.runtime)
                    || clears && configuredDomains.contains(.console)
            else {
                throw protocolViolation(
                    configuredDomains.contains(.console)
                        ? .operationalRuntimeEventWithoutRuntimeProjection
                        : .unconfiguredDomain(.runtime)
                )
            }
            try validateModelScope(
                scope,
                in: &binding,
                runtimeMustAdvance: clears
            )
            let transaction = try consoleRuntimeStore.reduceRuntime(
                event,
                scope: scope
            )
            return WebInspectorCanonicalModelTransaction(
                consoleRuntime: transaction
            )

        case let .inspector(event):
            guard configuredDomains.contains(.dom) else {
                throw protocolViolation(.unconfiguredDomain(.dom))
            }
            try validateModelScope(scope, in: &binding, requireDOMReady: true)
            guard scope.target.id == binding.currentPageID else {
                throw protocolViolation(.inspectorSelectionOutsideCurrentDocument)
            }
            switch event {
            case let .inspect(object, _):
                let objectID =
                    object.subtype?.rawValue == "node"
                    ? object.id
                    : nil
                return WebInspectorCanonicalModelTransaction(
                    actions: [
                        .inspectRemoteObject(scope: scope, objectID: objectID)
                    ]
                )
            case .unknown:
                return WebInspectorCanonicalModelTransaction()
            }
        }
    }

    private mutating func reduceNetwork(
        _ event: Network.Event,
        scope: ModelEventScope,
        binding: BindingState,
        origin: CanonicalNetworkEventOrigin
    ) throws -> WebInspectorCanonicalModelTransaction {
        let networkScope = try canonicalNetworkScope(
            for: event,
            modelScope: scope,
            binding: binding
        )
        let rawID = Self.rawRequestID(in: event)
        let hasPendingConsoleReference =
            rawID.map {
                !consoleRuntimeStore.unresolvedConsoleMessageIDs(for: $0).isEmpty
            } ?? false

        if hasPendingConsoleReference {
            var nextNetwork = networkStore
            var nextConsole = consoleRuntimeStore
            let networkTransaction = try nextNetwork.reduce(
                event,
                scope: networkScope,
                origin: origin
            )
            var consoleTransaction: CanonicalConsoleRuntimeTransaction?
            if let rawID,
                let requestID = nextNetwork.requestID(forRawRequestID: rawID)
            {
                consoleTransaction = try nextConsole.resolveNetworkRequest(
                    CanonicalConsoleNetworkRequestResolution(
                        rawRequestID: rawID,
                        requestID: requestID
                    )
                )
            }
            networkStore = nextNetwork
            consoleRuntimeStore = nextConsole
            return WebInspectorCanonicalModelTransaction(
                network: networkTransaction,
                consoleRuntime: consoleTransaction
            )
        }

        let transaction = try networkStore.reduce(
            event,
            scope: networkScope,
            origin: origin
        )
        return WebInspectorCanonicalModelTransaction(network: transaction)
    }

    private func canonicalNetworkScope(
        for event: Network.Event,
        modelScope: ModelEventScope,
        binding: BindingState
    ) throws -> WebInspectorCanonicalNetworkEventScope {
        guard case let .requestWillBeSent(rawID, request, _, _, _, _) = event
        else {
            return WebInspectorCanonicalNetworkEventScope(
                modelScope: modelScope
            )
        }
        let eventScope = WebInspectorCanonicalNetworkEventScope(
            modelScope: modelScope
        )
        switch networkStore.requestOriginResolution(
            forRawRequestID: rawID,
            scope: eventScope
        ) {
        case let .existing(membership):
            return WebInspectorCanonicalNetworkEventScope(
                modelScope: modelScope,
                membership: membership
            )
        case .notRequired:
            return eventScope
        case .required:
            break
        }
        guard
            let requestOrigin = request.origin
        else {
            return WebInspectorCanonicalNetworkEventScope(
                modelScope: modelScope
            )
        }

        let origin: CanonicalNetworkRequestOrigin
        let authority: CanonicalNetworkRegisteredTargetAuthority?
        if let rawTargetID = requestOrigin.targetID {
            let targetID = WebInspectorTarget.ID(rawTargetID)
            origin = .protocolTarget(targetID)
            // Worker targets are not part of the current page/frame model
            // graph. Do not borrow the delivering agent's authority for an
            // origin that the graph owner has not registered.
            authority = canonicalNetworkTargetAuthority(
                for: targetID,
                binding: binding
            )
        } else if let targetID = requestOrigin.mappedFrameTargetID {
            guard binding.targets[targetID] != nil else {
                throw protocolViolation(
                    .networkMappedFrameTargetUnavailable(
                        frameID: requestOrigin.frameID,
                        targetID: targetID
                    )
                )
            }
            origin = .mappedFrame(
                frameID: requestOrigin.frameID,
                targetID: targetID
            )
            guard let resolvedAuthority = canonicalNetworkTargetAuthority(
                for: targetID,
                binding: binding
            ) else {
                preconditionFailure(
                    "A registered canonical Network frame target has no authority."
                )
            }
            authority = resolvedAuthority
        } else {
            origin = .eventTarget(modelScope.target.id)
            guard let eventAuthority = canonicalNetworkTargetAuthority(
                for: modelScope.target.id,
                binding: binding
            ) else {
                preconditionFailure(
                    "A validated canonical Network event target has no authority."
                )
            }
            authority = eventAuthority
        }

        return WebInspectorCanonicalNetworkEventScope(
            modelScope: modelScope,
            origin: origin,
            targetAuthority: authority,
            frameID: requestOrigin.frameID,
            loaderID: requestOrigin.loaderID
        )
    }

    private func canonicalNetworkTargetAuthority(
        for targetID: WebInspectorTarget.ID,
        binding: BindingState
    ) -> CanonicalNetworkRegisteredTargetAuthority? {
        guard binding.targets[targetID] != nil else {
            return nil
        }
        guard let navigationEpoch = binding.navigationEpochs[targetID] else {
            preconditionFailure(
                "A canonical Network target has no navigation authority."
            )
        }
        return CanonicalNetworkRegisteredTargetAuthority(
            targetID: targetID,
            navigationEpoch: navigationEpoch,
            domBindingEpoch: binding.DOMAuthorities[targetID]?
                .scope.domBindingEpoch
        )
    }

    func consoleNetworkResolution(
        for event: Console.Event
    ) -> CanonicalConsoleNetworkRequestResolution? {
        guard case let .messageAdded(message) = event,
            let rawID = message.networkRequestID,
            let requestID = networkStore.requestID(forRawRequestID: rawID)
        else {
            return nil
        }
        return CanonicalConsoleNetworkRequestResolution(
            rawRequestID: rawID,
            requestID: requestID
        )
    }

    static func rawRequestID(
        in event: Network.Event
    ) -> Network.Request.ID? {
        switch event {
        case let .requestWillBeSent(id, _, _, _, _, _),
            let .responseReceived(id, _, _, _),
            let .dataReceived(id, _, _, _),
            let .loadingFinished(id, _, _, _),
            let .loadingFailed(id, _, _, _),
            let .requestServedFromMemoryCache(id, _, _, _, _):
            id
        case let .webSocket(event):
            switch event {
            case let .created(id, _),
                let .handshakeRequest(id, _, _),
                let .handshakeResponse(id, _, _),
                let .closed(id, _),
                let .frameSent(id, _, _),
                let .frameReceived(id, _, _),
                let .error(id, _, _):
                id
            case .other:
                nil
            }
        case .unknown:
            nil
        }
    }
}

private extension WebInspectorCanonicalModelStore {
    private mutating func reduceTargetLifecycle(
        _ event: ModelTargetLifecycleEvent,
        scope: ModelEventScope,
        binding: inout BindingState
    ) throws -> WebInspectorCanonicalModelTransaction {
        switch event {
        case .targetCreated:
            guard binding.targets[scope.target.id] == nil,
                scope.target == scope.agentTarget
            else {
                throw protocolViolation(.invalidTargetLifecycle)
            }
            try installTarget(scope, in: &binding)
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [.targetCreated(scope.target)]
            )

        case .targetDestroyed:
            try validateModelScope(scope, in: &binding, requireDOMReady: false)
            guard scope.target.id != binding.currentPageID else {
                throw protocolViolation(
                    .currentPageTargetWasDestroyed(scope.target.id)
                )
            }
            let transaction = try removeTarget(
                scope.target.id,
                binding: &binding
            )
            return transaction

        case let .didCommitProvisionalTarget(oldTargetID):
            guard binding.targets[oldTargetID] != nil,
                binding.targets[scope.target.id] == nil,
                oldTargetID != scope.target.id,
                scope.target == scope.agentTarget,
                isValidTargetState(
                    ModelTargetState(
                        target: scope.target,
                        navigationEpoch: scope.navigationEpoch,
                        domBindingEpoch: scope.domBindingEpoch,
                        runtimeBindingEpoch: scope.runtimeBindingEpoch,
                        consoleBindingEpoch: scope.consoleBindingEpoch
                    )
                )
            else {
                throw protocolViolation(.invalidTargetLifecycle)
            }
            var transaction = try removeTarget(
                oldTargetID,
                binding: &binding,
                includesRemovalFeedChange: false
            )
            try installTarget(scope, in: &binding)
            if binding.currentPageID == oldTargetID {
                binding.currentPageID = scope.target.id
            }
            transaction.feedChanges.append(
                .provisionalTargetCommitted(
                    oldTargetID: oldTargetID,
                    newTarget: scope.target
                )
            )
            return transaction

        case let .frameNavigated(frame, isNewLoader):
            try validateRegisteredTargets(scope, in: binding)
            guard let previousNavigation = binding.navigationEpochs[scope.target.id],
                scope.navigationEpoch == previousNavigation
                    || previousNavigation.rawValue != UInt64.max
                        && scope.navigationEpoch.rawValue
                            == previousNavigation.rawValue + 1
            else {
                throw protocolViolation(
                    .navigationEpochDidNotAdvanceExactlyOnce(
                        targetID: scope.target.id,
                        previous: binding.navigationEpochs[scope.target.id]
                            ?? ModelNavigationEpoch(rawValue: 0),
                        proposed: scope.navigationEpoch
                    )
                )
            }
            try validateDOMBinding(scope, in: binding, requireReady: false)
            let runtimeAdvanced = try acceptAgentBindings(
                scope,
                in: &binding,
                runtimeMayAdvance: true
            )
            let navigationAdvanced = previousNavigation != scope.navigationEpoch
            let targetOwnsNavigatedFrame = scope.target.frameID == frame.id
            guard targetOwnsNavigatedFrame
                ? navigationAdvanced == isNewLoader
                : !navigationAdvanced
            else {
                throw protocolViolation(.invalidTargetLifecycle)
            }
            guard
                !requiresRuntimeBinding
                    || !isNewLoader
                    || runtimeAdvanced
            else {
                throw protocolViolation(
                    .runtimeBindingMismatch(scope.agentTarget.id)
                )
            }
            binding.navigationEpochs[scope.target.id] = scope.navigationEpoch

            var consoleTransaction: CanonicalConsoleRuntimeTransaction?
            if requiresRuntimeBinding, runtimeAdvanced || isNewLoader {
                var nextConsole = consoleRuntimeStore
                var transaction = CanonicalConsoleRuntimeTransaction()
                if runtimeAdvanced {
                    transaction.merge(
                        try nextConsole.runtimeBindingDidAdvance(scope: scope)
                    )
                }
                if isNewLoader, targetOwnsNavigatedFrame {
                    transaction.merge(
                        try nextConsole.semanticTargetNavigated(scope: scope)
                    )
                } else if isNewLoader {
                    transaction.merge(nextConsole.frameWasNavigated(frame.id))
                }
                consoleRuntimeStore = nextConsole
                if !transaction.isEmpty {
                    consoleTransaction = transaction
                }
            }
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [
                    .frameNavigated(
                        frameID: frame.id,
                        deliveryTargetID: scope.target.id,
                        navigationEpoch: scope.navigationEpoch
                    )
                ],
                consoleRuntime: consoleTransaction
            )

        case let .frameDetached(frameID):
            try validateModelScope(scope, in: &binding, requireDOMReady: false)
            var nextDOM = DOMReducer
            var nextCSS = CSSReducer
            var nextConsole = consoleRuntimeStore
            var DOMTransaction: WebInspectorCanonicalDOMTransaction?
            var CSSTransaction: WebInspectorCanonicalCSSTransaction?
            var consoleTransaction: CanonicalConsoleRuntimeTransaction?
            if configuredDomains.contains(.dom) {
                guard var reducer = nextDOM else {
                    preconditionFailure("Configured DOM frame detach lost its reducer.")
                }
                DOMTransaction = try reducer.frameWasDetached(frameID)
                nextDOM = reducer
            }
            if configuredDomains.contains(.css) {
                guard var reducer = nextCSS else {
                    preconditionFailure("Configured CSS frame detach lost its reducer.")
                }
                CSSTransaction = reducer.frameWasDetached(frameID)
                nextCSS = reducer
            }
            if requiresRuntimeBinding {
                consoleTransaction = nextConsole.frameWasDetached(frameID)
            }
            DOMReducer = nextDOM
            CSSReducer = nextCSS
            consoleRuntimeStore = nextConsole
            return WebInspectorCanonicalModelTransaction(
                feedChanges: [
                    .frameDetached(
                        frameID: frameID,
                        deliveryTargetID: scope.target.id
                    )
                ],
                DOM: DOMTransaction,
                CSS: CSSTransaction,
                consoleRuntime: consoleTransaction
            )
        }
    }

    private func installTarget(
        _ scope: ModelEventScope,
        in binding: inout BindingState
    ) throws {
        guard binding.targets[scope.target.id] == nil,
            scope.target == scope.agentTarget,
            isValidTargetState(
                ModelTargetState(
                    target: scope.target,
                    navigationEpoch: scope.navigationEpoch,
                    domBindingEpoch: scope.domBindingEpoch,
                    runtimeBindingEpoch: scope.runtimeBindingEpoch,
                    consoleBindingEpoch: scope.consoleBindingEpoch
                )
            )
        else {
            throw protocolViolation(.invalidTargetLifecycle)
        }
        binding.targets[scope.target.id] = scope.target
        binding.navigationEpochs[scope.target.id] = scope.navigationEpoch
        if configuredDomains.contains(.dom) {
            binding.DOMAuthorities[scope.target.id] = DOMAuthority(
                scope: scope,
                phase: .awaiting,
                isEstablishedInReducer: false
            )
        }
        if let epoch = scope.runtimeBindingEpoch {
            binding.runtimeBindingEpochs[scope.target.id] = epoch
        }
        if let epoch = scope.consoleBindingEpoch {
            binding.consoleBindingEpochs[scope.target.id] = epoch
        }
        if configuredDomains.contains(.css) {
            binding.isCSSReady = false
        }
    }

    private mutating func removeTarget(
        _ targetID: WebInspectorTarget.ID,
        binding: inout BindingState,
        includesRemovalFeedChange: Bool = true
    ) throws -> WebInspectorCanonicalModelTransaction {
        guard let target = binding.targets[targetID],
            let navigationEpoch = binding.navigationEpochs[targetID]
        else {
            throw protocolViolation(.unknownTarget(targetID))
        }
        let authority = binding.DOMAuthorities[targetID]
        let targetScope =
            authority?.scope
            ?? ModelEventScope(
                generation: binding.pageGeneration,
                target: target,
                agentTarget: target,
                navigationEpoch: navigationEpoch,
                domBindingEpoch: nil,
                runtimeBindingEpoch: binding.runtimeBindingEpochs[targetID],
                consoleBindingEpoch: binding.consoleBindingEpochs[targetID]
            )

        var nextNetwork = networkStore
        var nextDOM = DOMReducer
        var nextCSS = CSSReducer
        var nextConsole = consoleRuntimeStore
        let networkTransaction =
            configuredDomains.contains(.network)
            ? try nextNetwork.targetWasLost(targetID)
            : nil
        var DOMTransaction: WebInspectorCanonicalDOMTransaction?
        var CSSTransaction: WebInspectorCanonicalCSSTransaction?
        if authority?.isEstablishedInReducer == true {
            guard var reducer = nextDOM else {
                preconditionFailure("Established DOM target lost its reducer.")
            }
            DOMTransaction = try reducer.targetLost(
                scope: WebInspectorCanonicalDOMEventScope(modelScope: targetScope)
            )
            nextDOM = reducer
        }
        if configuredDomains.contains(.css) {
            let route = WebInspectorDOMTargetRouteStorage(
                semanticTargetID: targetScope.target.id,
                agentTargetID: targetScope.agentTarget.id
            )
            if binding.establishedCSSRoutes.contains(route) {
                guard var reducer = nextCSS else {
                    preconditionFailure("Established CSS target lost its reducer.")
                }
                CSSTransaction = try reducer.targetLost(
                    scope: WebInspectorCanonicalDOMEventScope(modelScope: targetScope)
                )
                nextCSS = reducer
                binding.establishedCSSRoutes.remove(route)
            }
            binding.isCSSReady = false
        }
        let consoleTransaction =
            configuredDomains.contains(.console)
                || configuredDomains.contains(.runtime)
            ? nextConsole.targetWasLost(targetID)
            : nil

        networkStore = nextNetwork
        DOMReducer = nextDOM
        CSSReducer = nextCSS
        consoleRuntimeStore = nextConsole
        binding.targets[targetID] = nil
        binding.navigationEpochs[targetID] = nil
        binding.DOMAuthorities[targetID] = nil
        binding.runtimeBindingEpochs[targetID] = nil
        binding.consoleBindingEpochs[targetID] = nil

        return WebInspectorCanonicalModelTransaction(
            feedChanges: includesRemovalFeedChange
                ? [.targetRemoved(targetID)]
                : [],
            network: networkTransaction,
            DOM: DOMTransaction,
            CSS: CSSTransaction,
            consoleRuntime: consoleTransaction
        )
    }
}

private extension CanonicalConsoleRuntimeTransaction {
    mutating func merge(_ other: CanonicalConsoleRuntimeTransaction?) {
        guard let other else {
            return
        }
        runtimeContextChanges.append(contentsOf: other.runtimeContextChanges)
        consoleMessageChanges.append(contentsOf: other.consoleMessageChanges)
        resourceInvalidations.append(contentsOf: other.resourceInvalidations)
    }
}

private extension WebInspectorCanonicalModelStore {
    private func validateRegisteredTargets(
        _ scope: ModelEventScope,
        in binding: BindingState
    ) throws {
        guard let target = binding.targets[scope.target.id] else {
            throw protocolViolation(.unknownTarget(scope.target.id))
        }
        guard target == scope.target else {
            throw protocolViolation(.targetScopeMismatch(scope.target.id))
        }
        guard let agent = binding.targets[scope.agentTarget.id] else {
            throw protocolViolation(.unknownTarget(scope.agentTarget.id))
        }
        guard agent == scope.agentTarget else {
            throw protocolViolation(.targetScopeMismatch(scope.agentTarget.id))
        }
    }

    private func validateNavigation(
        _ scope: ModelEventScope,
        in binding: BindingState
    ) throws {
        guard binding.navigationEpochs[scope.target.id] == scope.navigationEpoch else {
            throw protocolViolation(
                .navigationEpochDidNotAdvanceExactlyOnce(
                    targetID: scope.target.id,
                    previous: binding.navigationEpochs[scope.target.id]
                        ?? ModelNavigationEpoch(rawValue: 0),
                    proposed: scope.navigationEpoch
                )
            )
        }
    }

    private func validateDOMBinding(
        _ scope: ModelEventScope,
        in binding: BindingState,
        requireReady: Bool
    ) throws {
        if configuredDomains.contains(.dom) {
            guard let authority = binding.DOMAuthorities[scope.target.id],
                authority.scope.domBindingEpoch == scope.domBindingEpoch
            else {
                throw protocolViolation(.invalidDOMBinding(scope.target.id))
            }
            if requireReady, authority.phase != .ready {
                throw protocolViolation(.DOMEventBeforeBootstrap(scope.target.id))
            }
        } else if scope.domBindingEpoch != nil {
            throw protocolViolation(.invalidDOMBinding(scope.target.id))
        }
    }

    private mutating func validateModelScope(
        _ scope: ModelEventScope,
        in binding: inout BindingState,
        requireDOMReady: Bool = false,
        runtimeMustAdvance: Bool = false,
        consoleMustAdvance: Bool = false
    ) throws {
        try validateRegisteredTargets(scope, in: binding)
        try validateNavigation(scope, in: binding)
        try validateDOMBinding(scope, in: binding, requireReady: requireDOMReady)
        _ = try acceptAgentBindings(
            scope,
            in: &binding,
            runtimeMustAdvance: runtimeMustAdvance,
            consoleMustAdvance: consoleMustAdvance
        )
    }

    @discardableResult
    private mutating func acceptAgentBindings(
        _ scope: ModelEventScope,
        in binding: inout BindingState,
        runtimeMayAdvance: Bool = false,
        runtimeMustAdvance: Bool = false,
        consoleMustAdvance: Bool = false
    ) throws -> Bool {
        let targetID = scope.agentTarget.id
        var runtimeAdvanced = false
        if requiresRuntimeBinding {
            guard let previous = binding.runtimeBindingEpochs[targetID],
                let proposed = scope.runtimeBindingEpoch
            else {
                throw protocolViolation(.runtimeBindingMismatch(targetID))
            }
            runtimeAdvanced =
                previous.rawValue != UInt64.max
                && proposed.rawValue == previous.rawValue + 1
            let accepted =
                runtimeMustAdvance
                ? runtimeAdvanced
                : runtimeMayAdvance
                    ? proposed == previous || runtimeAdvanced
                    : proposed == previous
            guard accepted else {
                throw protocolViolation(.runtimeBindingMismatch(targetID))
            }
            if proposed != previous {
                binding.runtimeBindingEpochs[targetID] = proposed
                binding.epochMapMutationCount += 1
            }
        } else if scope.runtimeBindingEpoch != nil {
            throw protocolViolation(.runtimeBindingMismatch(targetID))
        }

        if configuredDomains.contains(.console) {
            guard let previous = binding.consoleBindingEpochs[targetID],
                let proposed = scope.consoleBindingEpoch
            else {
                throw protocolViolation(.consoleBindingMismatch(targetID))
            }
            let advanced =
                previous.rawValue != UInt64.max
                && proposed.rawValue == previous.rawValue + 1
            guard consoleMustAdvance ? advanced : proposed == previous else {
                throw protocolViolation(.consoleBindingMismatch(targetID))
            }
            if proposed != previous {
                binding.consoleBindingEpochs[targetID] = proposed
                binding.epochMapMutationCount += 1
            }
        } else if scope.consoleBindingEpoch != nil {
            throw protocolViolation(.consoleBindingMismatch(targetID))
        }
        return runtimeAdvanced
    }
}

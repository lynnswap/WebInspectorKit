import OSLog
import WebInspectorBridge
import WebInspectorEngine
import WebKit

private let inspectorLogger = Logger(subsystem: "WebInspectorKit", category: "DOMInspectorRuntime")
private let bootstrapRetryDelayNanoseconds: UInt64 = 50_000_000

enum DOMDocumentReloadMode: String, Equatable {
    case fresh = "fresh"
    case preserveUIState = "preserve-ui-state"
}

@MainActor
package final class DOMInspectorRuntime: NSObject {
    private final class RequestScope {}
    private struct DocumentScope {
        let documentScopeID: UInt64
        let requestScope: RequestScope
    }
    private struct DeferredDOMBundle {
        let bundle: DOMBundle
    }

    struct MutationContext: Equatable {
        let pageEpoch: Int
        let documentScopeID: UInt64
    }

    private enum Phase: Equatable {
        case idle(epoch: Int)
        case transitioning(epoch: Int, generation: UInt64)
        case bootstrapping(epoch: Int, generation: UInt64)

        var epoch: Int {
            switch self {
            case let .idle(epoch),
                 let .transitioning(epoch, _),
                 let .bootstrapping(epoch, _):
                epoch
            }
        }

        var generation: UInt64 {
            switch self {
            case .idle:
                0
            case let .transitioning(_, generation),
                 let .bootstrapping(_, generation):
                generation
            }
        }

        var allowsFrontendTraffic: Bool {
            if case .idle = self {
                return true
            }
            return false
        }

        var isTransitioning: Bool {
            if case .transitioning = self {
                return true
            }
            return false
        }
    }

    private struct TransitionContext {
        let epoch: Int
        let generation: UInt64
        let suspendedDeferredDOMBundles: [DeferredDOMBundle]
    }

    private struct PendingDocumentRequest: Equatable {
        let depth: Int
        let mode: DOMDocumentReloadMode
    }

    let session: DOMSession
    let bridge: DOMInspectorBridge
    let currentDocumentModel: DOMDocumentModel

    private var isReady = false
    private var phase: Phase = .idle(epoch: 0)
    private let mutationPipeline: DOMMutationSender
    private var configuration: DOMConfiguration
    private var configurationNeedsBootstrap = true
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: PendingDocumentRequest?
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskID = 0
    private var matchedStylesTask: Task<Void, Never>?
    private var matchedStylesRequestCount = 0
    private var selectorPathTask: Task<Void, Never>?
    private var selectorPathRequestCount = 0
    private var enqueuedMutationGeneration = 0
    private var discardedMutationGeneration = 0
    private let payloadNormalizer = DOMPayloadNormalizer()
    private let bridgeRuntime = WISPIRuntime.shared
    private var nextTransitionGeneration: UInt64 = 0
    var onRecoverableError: (@MainActor (String?) -> Void)?
    private var nextDocumentScopeID: UInt64 = 0
    private var currentDocumentScope = DocumentScope(documentScopeID: 0, requestScope: RequestScope())
    private var deferredDOMBundlesDuringBootstrap: [DeferredDOMBundle] = []
    private var needsFrontendDocumentRequestDrain = false
    private var needsFrontendChildNodeRetryDrain = false
    private var pendingSelectionOverrideLocalID: UInt64?
    private var pendingDocumentScopeSyncTask: Task<Bool, Never>?
    private var pendingDocumentScopeRecoveryTask: Task<Void, Never>?
    private var pendingDocumentScopeSyncGeneration: UInt64 = 0
    private var pendingDocumentScopeRecoveryGeneration: UInt64 = 0
    private let documentScopeResyncRetryAttempts = 12
    private let documentScopeResyncRetryDelayNanoseconds: UInt64 = 250_000_000
    private let pendingDocumentScopeSyncRetryAttempts = 3
    private let pendingDocumentScopeSyncRetryDelayNanoseconds: UInt64 = 500_000_000
    private var pendingDocumentScopeSyncPageEpoch: Int?
    private var pendingDocumentScopeSyncDocumentScopeID: UInt64?
    private var pendingDocumentScopeRecoveryPageEpoch: Int?
    private var pendingDocumentScopeRecoveryDocumentScopeID: UInt64?

#if DEBUG
    private var matchedStylesFetchOverride: (@MainActor (Int) async throws -> DOMMatchedStylesPayload)?
    var testConfigurationApplyOverride: (@MainActor (DOMConfiguration) async -> Void)?
    var testPreferredDepthApplyOverride: (@MainActor (Int) async -> Void)?
    var testDocumentRequestApplyOverride: (@MainActor (_ depth: Int, _ mode: DOMDocumentReloadMode) async -> Void)?
    var testFrontendDispatchOverride: (@MainActor (Any) async -> Bool)?
    var testDocumentScopeSyncOverride: (@MainActor (UInt64) async -> Void)?
    var testDocumentScopeSyncResultOverride: Bool?
    var testDocumentScopeResyncRetryAttemptsOverride: Int?
    var testDocumentScopeResyncRetryDelayNanosecondsOverride: UInt64?
    var testPendingDocumentScopeSyncRetryAttemptsOverride: Int?
    var testPendingDocumentScopeSyncRetryDelayNanosecondsOverride: UInt64?
#endif

    private var webView: InspectorWebView? {
        bridge.inspectorWebView
    }

    private var pageEpoch: Int {
        phase.epoch
    }

    private var currentRequestScope: RequestScope {
        currentDocumentScope.requestScope
    }

    init(session: DOMSession, documentModel: DOMDocumentModel) {
        self.session = session
        self.currentDocumentModel = documentModel
        bridge = DOMInspectorBridge()
        configuration = session.configuration
        mutationPipeline = DOMMutationSender(
            session: session,
            bridgeRuntime: bridgeRuntime,
            configuration: session.configuration
        )
        super.init()
        bridge.runtime = self
        session.bundleSink = bridge
    }

    convenience init(session: DOMSession) {
        self.init(session: session, documentModel: DOMDocumentModel())
    }

    func makeInspectorWebView() -> InspectorWebView {
        let inspectorWebView = bridge.makeInspectorWebView()
        mutationPipeline.attachWebView(inspectorWebView)
        return inspectorWebView
    }

    func detachInspectorWebView() {
        guard webView != nil else {
            return
        }
        resetInspectorState()
        mutationPipeline.attachWebView(nil)
        bridge.detachInspectorWebView()
    }

    func enqueueMutationBundle(_ bundle: Any, preservingInspectorState: Bool) {
        enqueuedMutationGeneration += 1
        mutationPipeline.enqueueMutationBundle(
            bundle,
            preservingInspectorState: preservingInspectorState,
            generation: enqueuedMutationGeneration,
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
    }

    func clearPendingMutationBundles() {
        discardedMutationGeneration = max(
            discardedMutationGeneration,
            mutationPipeline.clearPendingMutationBundles()
        )
    }

    var pendingMutationBundleCount: Int {
        mutationPipeline.pendingMutationBundleCount
    }

    func resetDocumentStoreForDetachment() {
        replaceCurrentDocumentModel()
        payloadNormalizer.resetForDocumentUpdate()
    }

    func performPageTransition<T>(
        resumeBootstrap: Bool = true,
        _ operation: (_ nextPageEpoch: Int) async -> T
    ) async -> T {
        let transition = beginTransition(advancePageEpoch: true)
        replaceCurrentDocumentModel()
        payloadNormalizer.resetForDocumentUpdate()
        await drainTransitionFlushIfNeeded()
        let result = await operation(transition.epoch)
        completeTransition(transition, resumeBootstrap: resumeBootstrap)
        return result
    }

    func setPreferredDepth(_ depth: Int, expectedPageEpoch: Int? = nil) async {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        pendingPreferredDepth = depth
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
    }

    func requestDocument(
        depth: Int,
        mode: DOMDocumentReloadMode,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: UInt64? = nil
    ) async -> Bool {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return false
        }
        guard acceptsExpectedDocumentScopeID(expectedDocumentScopeID) else {
            return false
        }
        if mode == .fresh {
            let transition = beginTransition(advancePageEpoch: false)
            let nextDocumentScope = makeNextDocumentScope()
            let currentProjectedDocumentScopeID = currentDocumentScope.documentScopeID
            let allowsMissingPageScopeSync = session.hasPageWebView == false
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  acceptsExpectedDocumentScopeID(expectedDocumentScopeID),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            let didResetChildRequests = await dispatchResetChildNodeRequestsToFrontend(
                pageEpoch: transition.epoch,
                documentScopeID: currentProjectedDocumentScopeID
            )
            guard didResetChildRequests else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            await drainTransitionFlushIfNeeded()
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  acceptsExpectedDocumentScopeID(expectedDocumentScopeID),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            let didSyncDocumentScope = await syncFreshRequestDocumentScopeID(
                nextDocumentScope.documentScopeID,
                allowsMissingPage: allowsMissingPageScopeSync,
                expectedPageEpoch: transition.epoch
            )
            guard didSyncDocumentScope else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  acceptsExpectedDocumentScopeID(expectedDocumentScopeID),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                adoptSyncedDocumentScopeAfterAbortedFreshRequest(
                    nextDocumentScope,
                    transition: transition
                )
                completeTransition(transition)
                return false
            }
            clearPendingMutationBundles()
            cancelMatchedStylesRequest()
            cancelSelectorPathRequest()
            currentDocumentScope = nextDocumentScope
            payloadNormalizer.resetForDocumentUpdate()
            currentDocumentModel.clearDocument(isFreshDocument: true)
            pendingDocumentRequest = .init(depth: depth, mode: mode)
            bridge.refreshBootstrapPayloadIfPossible()
            completeTransition(transition)
            await waitForCurrentBootstrapIfNeeded()
            return true
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return false
        }
        guard acceptsExpectedDocumentScopeID(expectedDocumentScopeID) else {
            return false
        }
        pendingDocumentRequest = .init(depth: depth, mode: mode)
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
        return true
    }

    private func syncFreshRequestDocumentScopeID(
        _ documentScopeID: UInt64,
        allowsMissingPage: Bool = false,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
        if session.hasPageWebView == false {
            session.prepareDocumentScopeID(documentScopeID)
#if DEBUG
            if let testDocumentScopeSyncOverride {
                await testDocumentScopeSyncOverride(documentScopeID)
                return testDocumentScopeSyncResultOverride ?? allowsMissingPage
            }
#endif
            return allowsMissingPage
        }
#if DEBUG
        if let testDocumentScopeSyncOverride {
            await testDocumentScopeSyncOverride(documentScopeID)
            return testDocumentScopeSyncResultOverride ?? true
        }
#endif
        while Task.isCancelled == false {
            let didSync = await performDocumentScopeSync(
                documentScopeID,
                expectedPageEpoch: expectedPageEpoch
            )
            if didSync {
                return true
            }
            if session.hasPageWebView == false {
                return false
            }
            if expectedPageEpoch != nil, acceptsExpectedPageEpoch(expectedPageEpoch) == false {
                return false
            }
            try? await Task.sleep(nanoseconds: documentScopeResyncRetryDelayNanosecondsValue)
            guard Task.isCancelled == false else {
                return false
            }
        }
        return false
    }

    func updateConfiguration(_ configuration: DOMConfiguration, expectedPageEpoch: Int? = nil) async {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        self.configuration = configuration
        mutationPipeline.updateConfiguration(configuration)
        configurationNeedsBootstrap = true
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
    }

    var currentPageEpoch: Int {
        pageEpoch
    }

    var currentDocumentScopeID: UInt64 {
        currentDocumentScope.documentScopeID
    }

    var currentMutationContext: MutationContext {
        .init(
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
    }

    var currentBootstrapPayload: [String: Any] {
        var payload: [String: Any] = [
            "config": frontendConfigurationPayload()
        ]
        if let pendingPreferredDepth {
            payload["preferredDepth"] = pendingPreferredDepth
        }
        if let pendingDocumentRequest {
            payload["pendingDocumentRequest"] = [
                "depth": pendingDocumentRequest.depth,
                "mode": pendingDocumentRequest.mode.rawValue,
                "pageEpoch": pageEpoch,
            ]
        }
        return payload
    }

    isolated deinit {
        bootstrapTask?.cancel()
        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeSyncGeneration &+= 1
        pendingDocumentScopeRecoveryGeneration &+= 1
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        mutationPipeline.reset()
        bridge.detachInspectorWebView()
    }
}

extension DOMInspectorRuntime {
    private var documentScopeResyncRetryAttemptsValue: Int {
#if DEBUG
        testDocumentScopeResyncRetryAttemptsOverride ?? documentScopeResyncRetryAttempts
#else
        documentScopeResyncRetryAttempts
#endif
    }

    private var documentScopeResyncRetryDelayNanosecondsValue: UInt64 {
#if DEBUG
        testDocumentScopeResyncRetryDelayNanosecondsOverride ?? documentScopeResyncRetryDelayNanoseconds
#else
        documentScopeResyncRetryDelayNanoseconds
#endif
    }

    private var pendingDocumentScopeSyncRetryAttemptsValue: Int {
#if DEBUG
        testPendingDocumentScopeSyncRetryAttemptsOverride ?? pendingDocumentScopeSyncRetryAttempts
#else
        pendingDocumentScopeSyncRetryAttempts
#endif
    }

    private var pendingDocumentScopeSyncRetryDelayNanosecondsValue: UInt64 {
#if DEBUG
        testPendingDocumentScopeSyncRetryDelayNanosecondsOverride ?? pendingDocumentScopeSyncRetryDelayNanoseconds
#else
        pendingDocumentScopeSyncRetryDelayNanoseconds
#endif
    }

    func matchesCurrentMutationContext(_ context: MutationContext?) -> Bool {
        guard let context else {
            return true
        }
        return pageEpoch == context.pageEpoch
            && currentDocumentScope.documentScopeID == context.documentScopeID
    }

    private func performDocumentScopeSync(
        _ documentScopeID: UInt64,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
#if DEBUG
        if let testDocumentScopeSyncOverride {
            await testDocumentScopeSyncOverride(documentScopeID)
            return testDocumentScopeSyncResultOverride ?? true
        }
#endif
        return await session.syncCurrentDocumentScopeIDIfNeeded(
            documentScopeID,
            expectedPageEpoch: expectedPageEpoch
        )
    }

    func syncMutationContextToPageIfNeeded(_ context: MutationContext) async -> Bool {
        guard session.hasPageWebView else {
            if matchesCurrentMutationContext(context) {
                session.prepareDocumentScopeID(context.documentScopeID)
            }
            return false
        }
        var remainingAttempts = documentScopeResyncRetryAttemptsValue
        while remainingAttempts > 0, Task.isCancelled == false {
            let didSync = await performDocumentScopeSync(
                context.documentScopeID,
                expectedPageEpoch: context.pageEpoch
            )
            if didSync {
                return true
            }
            if session.hasPageWebView == false {
                return false
            }
            if matchesCurrentMutationContext(context) == false {
                return false
            }
            remainingAttempts -= 1
            if remainingAttempts > 0 {
                try? await Task.sleep(nanoseconds: documentScopeResyncRetryDelayNanosecondsValue)
                guard Task.isCancelled == false else {
                    return false
                }
            }
        }
        guard matchesCurrentMutationContext(context) else {
            return false
        }
        syncCurrentDocumentScopeIDIfNeeded()
        return false
    }

    func setPendingSelectionOverride(localID: UInt64?) {
        pendingSelectionOverrideLocalID = localID.flatMap { $0 > 0 ? $0 : nil }
    }

    private func syncCurrentDocumentScopeIDIfNeeded() {
        let documentScopeID = currentDocumentScope.documentScopeID
        let pageEpoch = self.pageEpoch
        session.prepareDocumentScopeID(documentScopeID)
        if let pendingDocumentScopeRecoveryTask,
           pendingDocumentScopeRecoveryPageEpoch == pageEpoch,
           pendingDocumentScopeRecoveryDocumentScopeID == documentScopeID {
            _ = pendingDocumentScopeRecoveryTask
            return
        }

        if pendingDocumentScopeSyncPageEpoch != pageEpoch
            || pendingDocumentScopeSyncDocumentScopeID != documentScopeID {
            pendingDocumentScopeSyncTask?.cancel()
            pendingDocumentScopeSyncTask = nil
            pendingDocumentScopeSyncGeneration &+= 1
            pendingDocumentScopeSyncPageEpoch = nil
            pendingDocumentScopeSyncDocumentScopeID = nil
        }
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeRecoveryPageEpoch = pageEpoch
        pendingDocumentScopeRecoveryDocumentScopeID = documentScopeID
        pendingDocumentScopeRecoveryGeneration &+= 1
        let generation = pendingDocumentScopeRecoveryGeneration
        let recoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.finishPendingDocumentScopeRecoveryTask(
                    generation: generation,
                    pageEpoch: pageEpoch,
                    documentScopeID: documentScopeID
                )
            }
            var remainingRecoveryRetries = self.documentScopeResyncRetryAttemptsValue
            while Task.isCancelled == false,
                  remainingRecoveryRetries > 0,
                  self.session.hasPageWebView,
                  self.pageEpoch == pageEpoch,
                  self.currentDocumentScope.documentScopeID == documentScopeID {
                let didSync = await self.syncCurrentDocumentScopeIDIfNeeded(
                    documentScopeID: documentScopeID,
                    pageEpoch: pageEpoch
                )
                if didSync {
                    return
                }
                remainingRecoveryRetries -= 1
                guard self.session.hasPageWebView,
                      self.pageEpoch == pageEpoch,
                      self.currentDocumentScope.documentScopeID == documentScopeID,
                      remainingRecoveryRetries > 0,
                      Task.isCancelled == false
                else {
                    return
                }
                try? await Task.sleep(
                    nanoseconds: self.documentScopeResyncRetryDelayNanosecondsValue
                )
                guard Task.isCancelled == false else {
                    return
                }
            }
        }
        pendingDocumentScopeRecoveryTask = recoveryTask
    }

    private func syncCurrentDocumentScopeIDIfNeeded(
        documentScopeID: UInt64,
        pageEpoch: Int
    ) async -> Bool {
        if let pendingDocumentScopeSyncTask,
           pendingDocumentScopeSyncPageEpoch == pageEpoch,
           pendingDocumentScopeSyncDocumentScopeID == documentScopeID {
            return await pendingDocumentScopeSyncTask.value
        }

        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeSyncGeneration &+= 1
        let generation = pendingDocumentScopeSyncGeneration
        pendingDocumentScopeSyncPageEpoch = pageEpoch
        pendingDocumentScopeSyncDocumentScopeID = documentScopeID
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return false
            }
            let maxAttempts = self.pendingDocumentScopeSyncRetryAttemptsValue
            for attempt in 0..<maxAttempts {
                guard Task.isCancelled == false else {
                    self.finishPendingDocumentScopeSync(generation: generation)
                    return false
                }
                let didSync = await self.performDocumentScopeSync(
                    documentScopeID,
                    expectedPageEpoch: pageEpoch
                )
                guard self.pendingDocumentScopeSyncGeneration == generation else {
                    return false
                }
                if didSync {
                    self.finishPendingDocumentScopeSync(generation: generation)
                    return true
                }
                guard self.session.hasPageWebView,
                      self.pageEpoch == pageEpoch,
                      self.currentDocumentScope.documentScopeID == documentScopeID,
                      Task.isCancelled == false
                else {
                    self.finishPendingDocumentScopeSync(generation: generation)
                    return false
                }
                if attempt + 1 < maxAttempts {
                    try? await Task.sleep(
                        nanoseconds: self.pendingDocumentScopeSyncRetryDelayNanosecondsValue
                    )
                    guard Task.isCancelled == false else {
                        self.finishPendingDocumentScopeSync(generation: generation)
                        return false
                    }
                }
            }
            self.finishPendingDocumentScopeSync(generation: generation)
            return false
        }
        pendingDocumentScopeSyncTask = task
        return await task.value
    }

    private func finishPendingDocumentScopeSync(generation: UInt64) {
        guard pendingDocumentScopeSyncGeneration == generation else {
            return
        }
        pendingDocumentScopeSyncTask = nil
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
    }

    private func finishPendingDocumentScopeRecoveryTask(
        generation: UInt64,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) {
        guard pendingDocumentScopeRecoveryGeneration == generation,
              pendingDocumentScopeRecoveryPageEpoch == pageEpoch,
              pendingDocumentScopeRecoveryDocumentScopeID == documentScopeID
        else {
            return
        }
        pendingDocumentScopeRecoveryTask = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
    }

    private func makeNextDocumentScope() -> DocumentScope {
        nextDocumentScopeID &+= 1
        return .init(documentScopeID: nextDocumentScopeID, requestScope: RequestScope())
    }

    private func replaceCurrentDocumentModel() {
        let nextScope = makeNextDocumentScope()
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        currentDocumentScope = nextScope
        pendingSelectionOverrideLocalID = nil
        currentDocumentModel.clearDocument(isFreshDocument: true)
        syncCurrentDocumentScopeIDIfNeeded()
    }

    private func commitCurrentDocumentScope(
        _ nextScope: DocumentScope,
        clearCurrentContents: Bool
    ) {
        clearPendingMutationBundles()
        currentDocumentScope = nextScope
        pendingSelectionOverrideLocalID = nil
        if clearCurrentContents {
            currentDocumentModel.clearDocument(isFreshDocument: true)
        }
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        bridge.refreshBootstrapPayloadIfPossible()
        syncCurrentDocumentScopeIDIfNeeded()
    }

    private func advanceCurrentDocumentScope(clearCurrentContents: Bool) {
        commitCurrentDocumentScope(
            makeNextDocumentScope(),
            clearCurrentContents: clearCurrentContents
        )
    }

    private func adoptSyncedDocumentScopeAfterAbortedFreshRequest(
        _ nextScope: DocumentScope,
        transition: TransitionContext
    ) {
        guard pageEpoch == transition.epoch else {
            return
        }
        guard currentDocumentScope.documentScopeID < nextScope.documentScopeID else {
            return
        }
        restoreDeferredDOMBundles(
            from: transition,
            rebasedToDocumentScopeID: nextScope.documentScopeID
        )
        commitCurrentDocumentScope(nextScope, clearCurrentContents: true)
    }

    private func applyMutationEventsToCurrentDocumentModel(_ events: [DOMGraphMutationEvent]) {
        guard !events.isEmpty else {
            return
        }
        currentDocumentModel.applyMutationBundle(.init(events: events))
    }

    private func applyMutationBundleAcrossDocumentUpdates(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        var bufferedEvents: [DOMGraphMutationEvent] = []
        for event in bundle.events {
            switch event {
            case .documentUpdated:
                applyMutationEventsToCurrentDocumentModel(bufferedEvents)
                bufferedEvents.removeAll(keepingCapacity: true)
                payloadNormalizer.resetForDocumentUpdate()
                advanceCurrentDocumentScope(clearCurrentContents: true)
            default:
                bufferedEvents.append(event)
            }
        }

            applyMutationEventsToCurrentDocumentModel(bufferedEvents)
    }

    func updateMutationPipelineReadyState() {
        mutationPipeline.setReady(isReady && phase.allowsFrontendTraffic && bootstrapTask == nil && !hasPendingBootstrapWork)
    }

    func waitForCurrentBootstrapIfNeeded() async {
        guard let bootstrapTask else {
            return
        }
        let currentTaskID = bootstrapTaskID
        await bootstrapTask.value
        if bootstrapTaskID == currentTaskID {
            self.bootstrapTask = nil
        }
    }

    var hasConfigurationBootstrapEndpoint: Bool {
#if DEBUG
        webView != nil || testConfigurationApplyOverride != nil
#else
        webView != nil
#endif
    }

    var hasPreferredDepthBootstrapEndpoint: Bool {
#if DEBUG
        webView != nil || testPreferredDepthApplyOverride != nil
#else
        webView != nil
#endif
    }

    var hasDocumentRequestBootstrapEndpoint: Bool {
#if DEBUG
        webView != nil || testDocumentRequestApplyOverride != nil
#else
        webView != nil
#endif
    }

    var hasBootstrapExecutionEndpoint: Bool {
        if configurationNeedsBootstrap {
            return hasConfigurationBootstrapEndpoint
        }
        if pendingPreferredDepth != nil {
            return hasPreferredDepthBootstrapEndpoint
        }
        if pendingDocumentRequest != nil {
            return hasDocumentRequestBootstrapEndpoint
        }
        return false
    }

    var hasPendingBootstrapWork: Bool {
        configurationNeedsBootstrap || pendingPreferredDepth != nil || pendingDocumentRequest != nil
    }

    func acceptsExpectedPageEpoch(_ expectedPageEpoch: Int?) -> Bool {
        guard let expectedPageEpoch else {
            return true
        }
        return expectedPageEpoch == pageEpoch
    }

    func acceptsExpectedDocumentScopeID(_ expectedDocumentScopeID: UInt64?) -> Bool {
        guard let expectedDocumentScopeID else {
            return true
        }
        return expectedDocumentScopeID == currentDocumentScope.documentScopeID
    }

    func frontendConfigurationPayload() -> [String: Any] {
        [
            "snapshotDepth": configuration.snapshotDepth,
            "subtreeDepth": configuration.subtreeDepth,
            "autoUpdateDebounce": configuration.autoUpdateDebounce,
            "pageEpoch": pageEpoch,
            "documentScopeID": currentDocumentScope.documentScopeID,
        ]
    }

    func publishRecoverableError(_ message: String?) {
        onRecoverableError?(message)
    }

    func scheduleBootstrapIfNeeded() {
        guard bootstrapTask == nil, isReady, phase.isTransitioning == false, hasBootstrapExecutionEndpoint, hasPendingBootstrapWork else {
            return
        }

        let expectedPageEpoch = pageEpoch
        let expectedGeneration = phase.generation
        phase = .bootstrapping(epoch: expectedPageEpoch, generation: expectedGeneration)
        bootstrapTaskID += 1
        let taskID = bootstrapTaskID
        bootstrapTask = Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.bootstrapTaskID == taskID {
                    self.bootstrapTask = nil
                }
                if self.pageEpoch == expectedPageEpoch, self.phase.generation == expectedGeneration {
                    if self.hasPendingBootstrapWork {
                        self.phase = .bootstrapping(epoch: expectedPageEpoch, generation: expectedGeneration)
                    } else {
                        self.phase = .idle(epoch: expectedPageEpoch)
                    }
                }
                self.updateMutationPipelineReadyState()
                self.drainDeferredFrontendDocumentRequestIfNeeded()
                self.drainDeferredFrontendChildNodeRetryIfNeeded()
                if self.isReady, self.pageEpoch == expectedPageEpoch, self.hasPendingBootstrapWork {
                    self.scheduleBootstrapIfNeeded()
                }
            }

            while Task.isCancelled == false,
                  self.isReady,
                  self.hasBootstrapExecutionEndpoint,
                  self.pageEpoch == expectedPageEpoch,
                  self.hasPendingBootstrapWork {
                let didApply = await self.performBootstrapPass(expectedPageEpoch: expectedPageEpoch)
                if didApply {
                    continue
                }
                try? await Task.sleep(nanoseconds: bootstrapRetryDelayNanoseconds)
            }
        }
    }

    func performBootstrapPass(expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }

        if configurationNeedsBootstrap {
            guard await applyConfigurationToInspector(expectedPageEpoch: expectedPageEpoch) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
                return true
            }
            guard Task.isCancelled == false else {
                return true
            }
            configurationNeedsBootstrap = false
        }

        if let depth = pendingPreferredDepth {
            guard await applyPreferredDepthNow(depth, expectedPageEpoch: expectedPageEpoch) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
                return true
            }
            guard Task.isCancelled == false else {
                return true
            }
            if pendingPreferredDepth == depth {
                pendingPreferredDepth = nil
            }
        }

        if let request = pendingDocumentRequest {
            guard await requestDocumentNow(
                depth: request.depth,
                mode: request.mode,
                expectedPageEpoch: expectedPageEpoch
            ) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
                return true
            }
            guard Task.isCancelled == false else {
                return true
            }
            if pendingDocumentRequest == request {
                pendingDocumentRequest = nil
            }
        }

        guard Task.isCancelled == false else {
            return true
        }
        applyDeferredDOMBundlesIfNeeded(expectedPageEpoch: expectedPageEpoch)

        publishRecoverableError(nil)
        return true
    }

    func applyConfigurationToInspector(expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }
        let config = frontendConfigurationPayload()
#if DEBUG
        if let testConfigurationApplyOverride {
            await testConfigurationApplyOverride(configuration)
            return true
        }
#endif
        guard let webView else {
            publishRecoverableError("Inspector web view unavailable")
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                """
                (function(config) {
                    if (window.webInspectorDOMFrontend?.updateConfig) {
                        window.webInspectorDOMFrontend.updateConfig(config);
                        return;
                    }
                    const bootstrap = window.__wiDOMFrontendBootstrap || (window.__wiDOMFrontendBootstrap = {});
                    bootstrap.config = { ...(bootstrap.config || {}), ...config };
                })(config);
                """,
                arguments: [
                    "config": config,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("apply config failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func beginTransition(advancePageEpoch: Bool) -> TransitionContext {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeSyncTask = nil
        pendingDocumentScopeRecoveryTask = nil
        pendingDocumentScopeSyncGeneration &+= 1
        pendingDocumentScopeRecoveryGeneration &+= 1
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
        let suspendedDeferredDOMBundles = deferredDOMBundlesDuringBootstrap
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        nextTransitionGeneration &+= 1
        let generation = nextTransitionGeneration
        let nextEpoch = pageEpoch + (advancePageEpoch ? 1 : 0)
        phase = .transitioning(epoch: nextEpoch, generation: generation)
        if advancePageEpoch {
            configurationNeedsBootstrap = true
        }
        mutationPipeline.setReady(false)
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        return .init(
            epoch: nextEpoch,
            generation: generation,
            suspendedDeferredDOMBundles: suspendedDeferredDOMBundles
        )
    }

    private func restoreDeferredDOMBundles(
        from transition: TransitionContext,
        rebasedToDocumentScopeID documentScopeID: UInt64? = nil
    ) {
        guard !transition.suspendedDeferredDOMBundles.isEmpty else {
            return
        }
        let restoredBundles = transition.suspendedDeferredDOMBundles.map { entry in
            DeferredDOMBundle(
                bundle: rebasedDOMBundle(
                    entry.bundle,
                    documentScopeID: documentScopeID ?? entry.bundle.documentScopeID
                )
            )
        }
        deferredDOMBundlesDuringBootstrap = restoredBundles + deferredDOMBundlesDuringBootstrap
    }

    private func rebasedDOMBundle(_ bundle: DOMBundle, documentScopeID: UInt64?) -> DOMBundle {
        switch bundle.payload {
        case let .jsonString(rawJSON):
            return .init(
                rawJSON: rawJSON,
                pageEpoch: bundle.pageEpoch,
                documentScopeID: documentScopeID
            )
        case let .objectEnvelope(objectEnvelope):
            return .init(
                objectEnvelope: objectEnvelope,
                pageEpoch: bundle.pageEpoch,
                documentScopeID: documentScopeID
            )
        }
    }

    private func drainTransitionFlushIfNeeded(resetCompletedGeneration: Bool = true) async {
        discardedMutationGeneration = max(
            discardedMutationGeneration,
            await mutationPipeline.cancelAndDrainFlushIfNeeded(
                resetCompletedGeneration: resetCompletedGeneration
            )
        )
    }

    private func completeTransition(
        _ transition: TransitionContext,
        resumeBootstrap: Bool = true
    ) {
        guard pageEpoch == transition.epoch, phase.generation == transition.generation else {
            return
        }
        enqueuedMutationGeneration = 0
        discardedMutationGeneration = 0
        if resumeBootstrap, hasPendingBootstrapWork {
            phase = .bootstrapping(epoch: transition.epoch, generation: transition.generation)
        } else {
            phase = .idle(epoch: transition.epoch)
        }
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        drainDeferredFrontendDocumentRequestIfNeeded()
        drainDeferredFrontendChildNodeRetryIfNeeded()
        if resumeBootstrap {
            scheduleBootstrapIfNeeded()
        }
    }

    func resetInspectorState() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeSyncTask = nil
        pendingDocumentScopeRecoveryTask = nil
        pendingDocumentScopeSyncGeneration &+= 1
        pendingDocumentScopeRecoveryGeneration &+= 1
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        isReady = false
        configurationNeedsBootstrap = true
        pendingPreferredDepth = nil
        pendingDocumentRequest = nil
        enqueuedMutationGeneration = 0
        discardedMutationGeneration = 0
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        needsFrontendDocumentRequestDrain = false
        needsFrontendChildNodeRetryDrain = false
        pendingSelectionOverrideLocalID = nil
        phase = .idle(epoch: pageEpoch)
        updateMutationPipelineReadyState()
        mutationPipeline.reset()
    }

    func applyPreferredDepthNow(_ depth: Int, expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }
#if DEBUG
        if let testPreferredDepthApplyOverride {
            await testPreferredDepthApplyOverride(depth)
            return true
        }
#endif
        guard let webView else {
            publishRecoverableError("Inspector web view unavailable")
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                """
                (function(depth, pageEpoch) {
                    if (window.webInspectorDOMFrontend?.setPreferredDepth) {
                        window.webInspectorDOMFrontend.setPreferredDepth(depth, pageEpoch);
                        return;
                    }
                    const bootstrap = window.__wiDOMFrontendBootstrap || (window.__wiDOMFrontendBootstrap = {});
                    bootstrap.preferredDepth = depth;
                })(depth, pageEpoch);
                """,
                arguments: [
                    "depth": depth,
                    "pageEpoch": pageEpoch,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("send preferred depth failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func requestDocumentNow(depth: Int, mode: DOMDocumentReloadMode, expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }
#if DEBUG
        if let testDocumentRequestApplyOverride {
            await testDocumentRequestApplyOverride(depth, mode)
            return true
        }
#endif
        let requestScope = currentRequestScope
        let requestDocumentScopeID = currentDocumentScope.documentScopeID
        do {
            let payload = try await session.captureSnapshotPayload(maxDepth: depth)
            let (payloadForDispatch, appliedSelectionOverride) = payloadByApplyingPendingSelectionOverride(payload)
            guard pageEpoch == expectedPageEpoch, currentRequestScope === requestScope else {
                needsFrontendDocumentRequestDrain = true
                _ = await dispatchRejectDocumentRequestToFrontend(
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID
                )
                return true
            }
            guard await dispatchFullSnapshotToFrontend(
                payloadForDispatch,
                mode: mode.rawValue,
                pageEpoch: expectedPageEpoch,
                documentScopeID: requestDocumentScopeID,
                requestScope: requestScope
            ) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch, currentRequestScope === requestScope else {
                return true
            }
            if let snapshot = payloadNormalizer.normalizeSnapshot(payloadForDispatch) {
                currentDocumentModel.replaceDocument(with: snapshot, isFreshDocument: false)
                if appliedSelectionOverride {
                    pendingSelectionOverrideLocalID = nil
                }
            }
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func payloadByApplyingPendingSelectionOverride(_ payload: Any) -> (payload: Any, applied: Bool) {
        guard let pendingSelectionOverrideLocalID else {
            return (payload, false)
        }
        if var dictionary = payload as? [String: Any] {
            dictionary["selectedNodeId"] = pendingSelectionOverrideLocalID
            return (dictionary, true)
        }
        if let dictionary = payload as? NSDictionary {
            var copied = dictionary as? [String: Any] ?? [:]
            copied["selectedNodeId"] = pendingSelectionOverrideLocalID
            return (copied, true)
        }
        if let json = payload as? String,
           let data = json.data(using: .utf8),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["selectedNodeId"] = pendingSelectionOverrideLocalID
            return (object, true)
        }
        return (payload, false)
    }

    func startMatchedStylesRequest(nodeID: Int, selectionEntry: DOMNodeModel) {
        cancelMatchedStylesRequest()
        matchedStylesRequestCount += 1
        let requestGeneration = matchedStylesRequestCount
        let requestScope = currentRequestScope
        let selectionDocumentScopeID = currentDocumentScope.documentScopeID
        currentDocumentModel.beginMatchedStylesLoading(for: selectionEntry)

        matchedStylesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.fetchMatchedStyles(nodeID: nodeID)
                if Task.isCancelled {
                    return
                }
                guard self.isCurrentMatchedStylesRequest(
                    generation: requestGeneration,
                    nodeID: nodeID,
                    documentScopeID: selectionDocumentScopeID
                ),
                self.currentRequestScope === requestScope
                else {
                    return
                }
                guard let currentSelection = self.currentSelectedEntry(
                    nodeID: nodeID,
                    documentScopeID: selectionDocumentScopeID
                ) else {
                    return
                }
                self.currentDocumentModel.applyMatchedStyles(payload, for: currentSelection)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                guard self.isCurrentMatchedStylesRequest(
                    generation: requestGeneration,
                    nodeID: nodeID,
                    documentScopeID: selectionDocumentScopeID
                ),
                self.currentRequestScope === requestScope
                else {
                    return
                }
                guard let currentSelection = self.currentSelectedEntry(
                    nodeID: nodeID,
                    documentScopeID: selectionDocumentScopeID
                ) else {
                    return
                }
                self.currentDocumentModel.clearMatchedStyles(for: currentSelection)
                inspectorLogger.debug("matched styles fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func fetchMatchedStyles(nodeID: Int) async throws -> DOMMatchedStylesPayload {
#if DEBUG
        if let matchedStylesFetchOverride {
            return try await matchedStylesFetchOverride(nodeID)
        }
#endif
        return try await session.matchedStyles(nodeId: nodeID)
    }

    func isCurrentMatchedStylesRequest(generation: Int, nodeID: Int, documentScopeID: UInt64) -> Bool {
        matchedStylesRequestCount == generation
            && currentSelectedEntry(nodeID: nodeID, documentScopeID: documentScopeID) != nil
    }

    func cancelMatchedStylesRequest() {
        matchedStylesTask?.cancel()
        matchedStylesTask = nil
    }

    func startSelectorPathRequest(nodeID: Int, selectionEntry: DOMNodeModel) {
        cancelSelectorPathRequest()
        selectorPathRequestCount += 1
        let requestGeneration = selectorPathRequestCount
        let requestScope = currentRequestScope
        let selectionDocumentScopeID = currentDocumentScope.documentScopeID

        selectorPathTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let selectorPath = try await self.session.selectorPath(nodeId: nodeID)
                guard Task.isCancelled == false else {
                    return
                }
                guard self.selectorPathRequestCount == requestGeneration,
                      self.currentRequestScope === requestScope,
                      self.currentSelectedEntry(nodeID: nodeID, documentScopeID: selectionDocumentScopeID) != nil
                else {
                    return
                }
                guard let currentSelection = self.currentSelectedEntry(
                    nodeID: nodeID,
                    documentScopeID: selectionDocumentScopeID
                ) else {
                    return
                }
                self.currentDocumentModel.applySelectorPath(selectorPath, for: currentSelection)
            } catch {
                guard self.selectorPathRequestCount == requestGeneration,
                      self.currentRequestScope === requestScope,
                      self.currentSelectedEntry(nodeID: nodeID, documentScopeID: selectionDocumentScopeID) != nil
                else {
                    return
                }
                guard let currentSelection = self.currentSelectedEntry(
                    nodeID: nodeID,
                    documentScopeID: selectionDocumentScopeID
                ) else {
                    return
                }
                self.currentDocumentModel.applySelectorPath("", for: currentSelection)
                return
            }
        }
    }

    func cancelSelectorPathRequest() {
        selectorPathTask?.cancel()
        selectorPathTask = nil
    }

    private func restartSelectionDependentRequestsIfNeeded() {
        guard let selected = currentDocumentModel.selectedNode,
              let nodeID = selected.backendNodeID else {
            return
        }
        if selected.selectorPath.isEmpty {
            startSelectorPathRequest(nodeID: nodeID, selectionEntry: selected)
        }
        if selected.isLoadingMatchedStyles || selected.matchedStyles.isEmpty {
            startMatchedStylesRequest(nodeID: nodeID, selectionEntry: selected)
        }
    }

    func applySelectionDelta(_ delta: DOMGraphDelta) {
        switch delta {
        case let .selection(selectionPayload):
            currentDocumentModel.applySelectionSnapshot(selectionPayload)
        case let .selectorPath(selectorPayload):
            currentDocumentModel.applySelectorPath(selectorPayload)
        case .snapshot, .mutations, .replaceSubtree:
            return
        }
    }

    func parseIntegerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String, let parsed = Int(value) {
            return parsed
        }
        return nil
    }

    func currentSelectedEntry(nodeID: Int, documentScopeID: UInt64) -> DOMNodeModel? {
        guard currentDocumentScope.documentScopeID == documentScopeID,
              let selectedEntry = currentDocumentModel.selectedNode,
              selectedEntry.backendNodeID == nodeID
        else {
            return nil
        }
        return selectedEntry
    }
}

extension DOMInspectorRuntime {
    private func canDispatchFrontendPayload(
        pageEpoch: Int,
        documentScopeID: UInt64,
        requestScope: RequestScope
    ) -> Bool {
        self.pageEpoch == pageEpoch
            && currentDocumentScope.documentScopeID == documentScopeID
            && currentRequestScope === requestScope
    }

    @discardableResult
    private func dispatchFullSnapshotToFrontend(
        _ payload: Any,
        mode: String,
        pageEpoch: Int,
        documentScopeID: UInt64,
        requestScope: RequestScope
    ) async -> Bool {
        guard canDispatchFrontendPayload(
            pageEpoch: pageEpoch,
            documentScopeID: documentScopeID,
            requestScope: requestScope
        ) else {
            return true
        }
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "fullSnapshot",
                "payload": payload,
                "mode": mode,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return true
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applyFullSnapshot?.(payload, mode, pageEpoch, documentScopeID)",
                arguments: [
                    "payload": payload,
                    "mode": mode,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch full snapshot failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchSubtreePayloadToFrontend(
        _ payload: Any,
        pageEpoch: Int,
        documentScopeID: UInt64,
        requestScope: RequestScope
    ) async -> Bool {
        guard canDispatchFrontendPayload(
            pageEpoch: pageEpoch,
            documentScopeID: documentScopeID,
            requestScope: requestScope
        ) else {
            return true
        }
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "subtree",
                "payload": payload,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applySubtreePayload?.(payload, pageEpoch, documentScopeID)",
                arguments: [
                    "payload": payload,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch subtree failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchCompleteChildNodeRequestToFrontend(
        nodeID: Int,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "completeChildNodeRequest",
                "nodeId": nodeID,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.completeChildNodeRequest?.(nodeId, pageEpoch, documentScopeID)",
                arguments: [
                    "nodeId": nodeID,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request completion failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchRejectChildNodeRequestToFrontend(
        nodeID: Int,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "rejectChildNodeRequest",
                "nodeId": nodeID,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.rejectChildNodeRequest?.(nodeId, pageEpoch, documentScopeID)",
                arguments: [
                    "nodeId": nodeID,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request rejection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchRetryQueuedChildNodeRequestsToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "retryQueuedChildNodeRequests",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return true
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.retryQueuedChildNodeRequests?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request retry failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchResetChildNodeRequestsToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "resetChildNodeRequests",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return true
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.resetChildNodeRequests?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchCompleteDocumentRequestToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "completeDocumentRequest",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.completeDocumentRequest?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch document request completion failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchRejectDocumentRequestToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "rejectDocumentRequest",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.rejectDocumentRequest?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch document request rejection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func handleDocumentRequestMessage(_ payload: Any) {
        guard let body = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]) else {
            return
        }
        let requestedDepth = parseIntegerValue(body["depth"]) ?? configuration.snapshotDepth
        let mode = DOMDocumentReloadMode(rawValue: body["mode"] as? String ?? "") ?? .fresh
        let expectedPageEpoch = pageEpoch
        let expectedDocumentScopeID = if let requestedDocumentScopeID = parseIntegerValue(body["documentScopeID"]),
                                         requestedDocumentScopeID >= 0 {
            UInt64(requestedDocumentScopeID)
        } else {
            currentDocumentScope.documentScopeID
        }
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            let didRequestDocument = await self.requestDocument(
                depth: requestedDepth,
                mode: mode,
                expectedPageEpoch: expectedPageEpoch,
                expectedDocumentScopeID: expectedDocumentScopeID
            )
            guard didRequestDocument == false else {
                return
            }
            _ = await self.dispatchRejectDocumentRequestToFrontend(
                pageEpoch: expectedPageEpoch,
                documentScopeID: expectedDocumentScopeID
            )
        }
    }

    func handleChildNodeRequestMessage(_ payload: Any) {
        guard let body = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]) else {
            return
        }
        let nodeID = parseIntegerValue(body["nodeId"]) ?? 0
        let depth = parseIntegerValue(body["depth"]) ?? configuration.subtreeDepth
        guard nodeID > 0 else {
            return
        }
        let expectedPageEpoch = pageEpoch
        let requestScope = currentRequestScope
        let requestDocumentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            do {
                let payload = try await self.session.captureSubtreePayload(nodeId: nodeID, maxDepth: depth)
                guard self.pageEpoch == expectedPageEpoch, self.currentRequestScope === requestScope else {
                    self.needsFrontendChildNodeRetryDrain = true
                    _ = await self.dispatchRejectChildNodeRequestToFrontend(
                        nodeID: nodeID,
                        pageEpoch: expectedPageEpoch,
                        documentScopeID: requestDocumentScopeID
                    )
                    return
                }
                let didDispatch = await self.dispatchSubtreePayloadToFrontend(
                    payload,
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID,
                    requestScope: requestScope
                )
                if !didDispatch {
                    _ = await self.dispatchCompleteChildNodeRequestToFrontend(
                        nodeID: nodeID,
                        pageEpoch: expectedPageEpoch,
                        documentScopeID: requestDocumentScopeID
                    )
                    return
                }
                guard self.pageEpoch == expectedPageEpoch, self.currentRequestScope === requestScope else {
                    return
                }
                if let delta = self.payloadNormalizer.normalizeBackendResponse(
                    method: "DOM.requestChildNodes",
                    responseObject: ["result": payload],
                    resetDocument: false
                ),
                   case let .replaceSubtree(root) = delta {
                    self.currentDocumentModel.applyMutationBundle(
                        .init(events: [.replaceSubtree(root: root)])
                    )
                }
            } catch {
                inspectorLogger.debug("capture subtree failed: \(error.localizedDescription, privacy: .public)")
                _ = await self.dispatchCompleteChildNodeRequestToFrontend(
                    nodeID: nodeID,
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID
                )
            }
        }
    }

    func handleHighlightRequestMessage(_ payload: Any) {
        guard let body = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]) else {
            return
        }
        let nodeID = parseIntegerValue(body["nodeId"]) ?? 0
        guard nodeID > 0 else {
            return
        }
        Task.immediateIfAvailable { [weak self] in
            await self?.session.highlight(nodeId: nodeID)
        }
    }

    func handleHideHighlightRequestMessage(_ payload: Any) {
        _ = payload
        Task.immediateIfAvailable { [weak self] in
            await self?.session.hideHighlight()
        }
    }

    func handleRejectedDocumentRequestMessage(pageEpoch: Int?, documentScopeID: UInt64?) {
        guard let pageEpoch, pageEpoch == self.pageEpoch else {
            return
        }
        needsFrontendDocumentRequestDrain = true
        let responseDocumentScopeID = documentScopeID ?? currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchRejectDocumentRequestToFrontend(
                pageEpoch: pageEpoch,
                documentScopeID: responseDocumentScopeID
            )
        }
    }

    func handleRejectedChildNodeRequestMessage(nodeID: Int?, pageEpoch: Int?, documentScopeID: UInt64?) {
        guard let nodeID, nodeID > 0, let pageEpoch, pageEpoch == self.pageEpoch else {
            return
        }
        needsFrontendChildNodeRetryDrain = true
        let responseDocumentScopeID = documentScopeID ?? currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchRejectChildNodeRequestToFrontend(
                nodeID: nodeID,
                pageEpoch: pageEpoch,
                documentScopeID: responseDocumentScopeID
            )
        }
    }

    private func applyBundleToCurrentDocumentStore(_ payload: Any) {
        guard let delta = payloadNormalizer.normalizeBundlePayload(payload) else {
            return
        }
        switch delta {
        case let .snapshot(snapshot, shouldResetDocument):
            payloadNormalizer.resetForDocumentUpdate()
            advanceCurrentDocumentScope(clearCurrentContents: shouldResetDocument)
            currentDocumentModel.replaceDocument(with: snapshot, isFreshDocument: shouldResetDocument)
        case let .mutations(bundle):
            applyMutationBundleAcrossDocumentUpdates(bundle)
            if bundle.events.contains(where: Self.isStructuralMutationEvent),
               let selectedEntry = currentDocumentModel.selectedNode,
               let nodeID = selectedEntry.backendNodeID {
                startSelectorPathRequest(nodeID: nodeID, selectionEntry: selectedEntry)
            }
        case let .replaceSubtree(root):
            currentDocumentModel.applyMutationBundle(.init(events: [.replaceSubtree(root: root)]))
            if let selectedEntry = currentDocumentModel.selectedNode,
               let nodeID = selectedEntry.backendNodeID {
                startSelectorPathRequest(nodeID: nodeID, selectionEntry: selectedEntry)
            }
        case let .selection(selection):
            currentDocumentModel.applySelectionSnapshot(selection)
        case let .selectorPath(selector):
            currentDocumentModel.applySelectorPath(selector)
        }
    }

    func domDidEmit(bundle: DOMBundle) {
        handleDOMBundle(bundle)
    }

    func handleDOMBundle(_ bundle: DOMBundle) {
        guard acceptsDOMBundle(documentScopeID: bundle.documentScopeID) else {
            return
        }
        if bootstrapTask != nil {
            deferredDOMBundlesDuringBootstrap.append(.init(bundle: bundle))
            return
        }
        applyDOMBundleToCurrentDocumentStore(bundle)
        enqueueMutationPayload(bundle)
    }

    private func applyDeferredDOMBundlesIfNeeded(expectedPageEpoch: Int) {
        guard pageEpoch == expectedPageEpoch else {
            deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
            return
        }
        guard !deferredDOMBundlesDuringBootstrap.isEmpty else {
            return
        }
        let bundles = deferredDOMBundlesDuringBootstrap
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        // Transition/reset clears this queue, so the remaining entries all belong to the
        // current bootstrap session and must replay in-order even if one bundle replaces the document.
        for entry in bundles {
            guard acceptsDOMBundle(documentScopeID: entry.bundle.documentScopeID) else {
                continue
            }
            applyDOMBundleToCurrentDocumentStore(entry.bundle)
            enqueueMutationPayload(entry.bundle)
        }
    }

    private func applyDOMBundleToCurrentDocumentStore(_ bundle: DOMBundle) {
        switch bundle.payload {
        case let .jsonString(rawJSON):
            applyBundleToCurrentDocumentStore(rawJSON)
        case let .objectEnvelope(object):
            applyBundleToCurrentDocumentStore(object)
        }
    }

    private func enqueueMutationPayload(_ bundle: DOMBundle) {
        switch bundle.payload {
        case let .jsonString(rawJSON):
            enqueueMutationBundle(rawJSON, preservingInspectorState: true)
        case let .objectEnvelope(object):
            enqueueMutationBundle(object, preservingInspectorState: true)
        }
    }

    func acceptsFrontendMessage(pageEpoch: Int?, documentScopeID: UInt64?) -> Bool {
        phase.allowsFrontendTraffic
            && (pageEpoch ?? 0) == self.pageEpoch
            && (documentScopeID == nil || documentScopeID == currentDocumentScope.documentScopeID)
    }

    private static func isStructuralMutationEvent(_ event: DOMGraphMutationEvent) -> Bool {
        switch event {
        case .childNodeInserted,
             .childNodeRemoved,
             .childNodeCountUpdated,
             .setChildNodes,
             .replaceSubtree,
             .documentUpdated:
            return true
        case .attributeModified,
             .attributeRemoved,
             .characterDataModified:
            return false
        }
    }

    private func drainDeferredFrontendDocumentRequestIfNeeded() {
        guard needsFrontendDocumentRequestDrain, isReady, phase.allowsFrontendTraffic else {
            return
        }
        needsFrontendDocumentRequestDrain = false
        let pageEpoch = self.pageEpoch
        let documentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchCompleteDocumentRequestToFrontend(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        }
    }

    private func drainDeferredFrontendChildNodeRetryIfNeeded() {
        guard needsFrontendChildNodeRetryDrain, isReady, phase.allowsFrontendTraffic else {
            return
        }
        needsFrontendChildNodeRetryDrain = false
        let pageEpoch = self.pageEpoch
        let documentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchRetryQueuedChildNodeRequestsToFrontend(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        }
    }

    func acceptsDOMBundle(documentScopeID: DOMDocumentScopeID?) -> Bool {
        !phase.isTransitioning
            && (documentScopeID == nil || documentScopeID == currentDocumentScope.documentScopeID)
    }

    func acceptsReadyMessage(pageEpoch: Int?, documentScopeID: UInt64?) -> Bool {
        (pageEpoch ?? 0) == self.pageEpoch
            && (documentScopeID == nil || documentScopeID == currentDocumentScope.documentScopeID)
    }

    func handleReadyMessage() {
        isReady = true
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
    }

    func handleLogMessage(_ payload: Any) {
        if let dictionary = payload as? NSDictionary,
           let logMessage = dictionary["message"] as? String {
            inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
        } else if let logMessage = payload as? String {
            inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
        }
    }

    func handleDOMSelectionMessage(_ payload: Any) {
        let previousSelectedSnapshot: (
            entry: DOMNodeModel,
            preview: String,
            path: [String],
            attributes: [DOMAttribute],
            styleRevision: Int
        )? = currentDocumentModel.selectedNode.map {
            (
                entry: $0,
                preview: $0.preview,
                path: $0.path,
                attributes: $0.attributes,
                styleRevision: $0.styleRevision
            )
        }
        applySelectionDelta(payloadNormalizer.normalizeSelectionPayload(payload))
        guard let selected = currentDocumentModel.selectedNode else {
            cancelMatchedStylesRequest()
            cancelSelectorPathRequest()
            return
        }

        guard let nodeID = selected.backendNodeID else {
            return
        }

        let didSelectNewNode = previousSelectedSnapshot.map { $0.entry !== selected } ?? true
        let didStyleRelevantSnapshotChange = !didSelectNewNode && (
            previousSelectedSnapshot?.preview != selected.preview
                || previousSelectedSnapshot?.path != selected.path
                || previousSelectedSnapshot?.attributes != selected.attributes
                || previousSelectedSnapshot?.styleRevision != selected.styleRevision
        )
        let shouldRefetchSelectorPath = selected.selectorPath.isEmpty
        let shouldRefetchMatchedStyles = !selected.isLoadingMatchedStyles
            && selected.matchedStyles.isEmpty
        if didSelectNewNode || didStyleRelevantSnapshotChange || shouldRefetchSelectorPath {
            startSelectorPathRequest(nodeID: nodeID, selectionEntry: selected)
        }
        if didSelectNewNode || didStyleRelevantSnapshotChange || shouldRefetchMatchedStyles {
            startMatchedStylesRequest(nodeID: nodeID, selectionEntry: selected)
        }
    }

}

#if DEBUG
extension DOMInspectorRuntime {
    func testAdvanceCurrentDocumentScopeWithoutClearingModel() {
        currentDocumentScope = makeNextDocumentScope()
    }

    func testSetPhaseIdleForCurrentPage() {
        phase = .idle(epoch: pageEpoch)
    }

    var testBundleFlushInterval: TimeInterval {
        mutationPipeline.currentBundleFlushInterval
    }

    var testHasPendingBundleFlushTask: Bool {
        mutationPipeline.hasPendingBundleFlushTask
    }

    var testHasActiveBundleFlushTask: Bool {
        mutationPipeline.hasActiveBundleFlushTask
    }

    func testSetReady(_ ready: Bool) {
        isReady = ready
        updateMutationPipelineReadyState()
        if ready {
            scheduleBootstrapIfNeeded()
        }
    }

    var testMutationFlushOverride: (@MainActor ([Any]) async -> Void)? {
        get { mutationPipeline.testApplyBundlesOverride }
        set { mutationPipeline.testApplyBundlesOverride = newValue }
    }

    var testBeforeMutationDispatchOverride: (@MainActor () async -> Void)? {
        get { mutationPipeline.testBeforeBundleDispatchOverride }
        set { mutationPipeline.testBeforeBundleDispatchOverride = newValue }
    }

    var testMatchedStylesRequestToken: Int {
        matchedStylesRequestCount
    }

    var testSelectorPathRequestToken: Int {
        selectorPathRequestCount
    }

    var testCompletedMutationGeneration: Int {
        mutationPipeline.completedMutationGeneration
    }

    var testDiscardedMutationGeneration: Int {
        discardedMutationGeneration
    }

    var testPendingSelectionOverrideLocalID: UInt64? {
        pendingSelectionOverrideLocalID
    }

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }

    func testWaitForReconcileForTesting() async {}

    func testResetInspectorStateForTesting() {
        resetInspectorState()
    }

    func testSyncCurrentDocumentScopeIDIfNeeded() async -> Bool {
        await syncCurrentDocumentScopeIDIfNeeded(
            documentScopeID: currentDocumentScope.documentScopeID,
            pageEpoch: pageEpoch
        )
    }

    func testWaitForBootstrapForTesting() async {
        await bootstrapTask?.value
    }

    var testMatchedStylesFetcher: (@MainActor (Int) async throws -> DOMMatchedStylesPayload)? {
        get { matchedStylesFetchOverride }
        set { matchedStylesFetchOverride = newValue }
    }
}
#endif

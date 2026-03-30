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
final class DOMInspectorRuntime: NSObject {
    private final class RequestScope {}
    private struct DocumentScope {
        let documentScopeID: UInt64
        let requestScope: RequestScope
    }
    private struct DeferredDOMBundle {
        let bundle: DOMBundle
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
    }

    private struct PendingDocumentRequest: Equatable {
        let depth: Int
        let mode: DOMDocumentReloadMode
    }

    let session: DOMSession
    let bridge: DOMInspectorBridge
    private var ownedDocumentStore = DOMDocumentStore()
    private var currentDocumentStoreOverride: DOMDocumentStore?
    private var onDocumentStoreReplacement: (@MainActor (DOMDocumentStore) -> Void)?

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

#if DEBUG
    private var matchedStylesFetchOverride: (@MainActor (Int) async throws -> DOMMatchedStylesPayload)?
    var testConfigurationApplyOverride: (@MainActor (DOMConfiguration) async -> Void)?
    var testPreferredDepthApplyOverride: (@MainActor (Int) async -> Void)?
    var testDocumentRequestApplyOverride: (@MainActor (_ depth: Int, _ mode: DOMDocumentReloadMode) async -> Void)?
    var testFrontendDispatchOverride: (@MainActor (Any) async -> Bool)?
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

    var currentDocumentStore: DOMDocumentStore {
        currentDocumentStoreOverride ?? ownedDocumentStore
    }

    init(session: DOMSession) {
        self.session = session
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

    func bindDocumentStore(
        _ documentStore: DOMDocumentStore,
        onReplacement: @escaping @MainActor (DOMDocumentStore) -> Void
    ) {
        currentDocumentStoreOverride = documentStore
        onDocumentStoreReplacement = onReplacement
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
        replaceCurrentDocumentStore()
        payloadNormalizer.resetForDocumentUpdate()
    }

    func performPageTransition<T>(
        resumeBootstrap: Bool = true,
        _ operation: (_ nextPageEpoch: Int) async -> T
    ) async -> T {
        let transition = beginTransition(advancePageEpoch: true)
        replaceCurrentDocumentStore()
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

    func requestDocument(depth: Int, mode: DOMDocumentReloadMode, expectedPageEpoch: Int? = nil) async {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        if mode == .fresh {
            let transition = beginTransition(advancePageEpoch: false)
            let nextDocumentScope = makeNextDocumentScope()
            let didResetChildRequests = await dispatchResetChildNodeRequestsToFrontend(
                pageEpoch: transition.epoch,
                documentScopeID: currentDocumentScope.documentScopeID
            )
            guard didResetChildRequests else {
                completeTransition(transition)
                return
            }
            await drainTransitionFlushIfNeeded()
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                completeTransition(transition)
                return
            }
            payloadNormalizer.resetForDocumentUpdate()
            commitCurrentDocumentScope(nextDocumentScope, clearCurrentContents: true)
            pendingDocumentRequest = .init(depth: depth, mode: mode)
            bridge.refreshBootstrapPayloadIfPossible()
            completeTransition(transition)
            await waitForCurrentBootstrapIfNeeded()
            return
        }
        pendingDocumentRequest = .init(depth: depth, mode: mode)
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
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
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        mutationPipeline.reset()
        bridge.detachInspectorWebView()
    }
}

extension DOMInspectorRuntime {
    private func syncCurrentDocumentScopeIDIfNeeded() {
        let documentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            await self?.session.syncCurrentDocumentScopeIDIfNeeded(documentScopeID)
        }
    }

    private func replaceBoundDocumentStore(with store: DOMDocumentStore) {
        if currentDocumentStoreOverride != nil {
            currentDocumentStoreOverride = store
            onDocumentStoreReplacement?(store)
        } else {
            ownedDocumentStore = store
        }
    }

    private func makeNextDocumentScope() -> DocumentScope {
        nextDocumentScopeID &+= 1
        return .init(documentScopeID: nextDocumentScopeID, requestScope: RequestScope())
    }

    private func replaceCurrentDocumentStore() {
        let nextScope = makeNextDocumentScope()
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        currentDocumentScope = nextScope
        replaceBoundDocumentStore(with: DOMDocumentStore())
        syncCurrentDocumentScopeIDIfNeeded()
    }

    private func commitCurrentDocumentScope(
        _ nextScope: DocumentScope,
        clearCurrentContents: Bool
    ) {
        clearPendingMutationBundles()
        currentDocumentScope = nextScope
        cancelMatchedStylesRequest()
        cancelSelectorPathRequest()
        if clearCurrentContents {
            currentDocumentStore.clearDocument()
        }
        bridge.refreshBootstrapPayloadIfPossible()
        syncCurrentDocumentScopeIDIfNeeded()
    }

    private func advanceCurrentDocumentScope(clearCurrentContents: Bool) {
        commitCurrentDocumentScope(
            makeNextDocumentScope(),
            clearCurrentContents: clearCurrentContents
        )
    }

    private func applyMutationEventsToCurrentDocumentStore(_ events: [DOMGraphMutationEvent]) {
        guard !events.isEmpty else {
            return
        }
        currentDocumentStore.applyMutationBundle(.init(events: events))
    }

    private func applyMutationBundleAcrossDocumentUpdates(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        var bufferedEvents: [DOMGraphMutationEvent] = []
        for event in bundle.events {
            switch event {
            case .documentUpdated:
                applyMutationEventsToCurrentDocumentStore(bufferedEvents)
                bufferedEvents.removeAll(keepingCapacity: true)
                payloadNormalizer.resetForDocumentUpdate()
                advanceCurrentDocumentScope(clearCurrentContents: true)
            default:
                bufferedEvents.append(event)
            }
        }

        applyMutationEventsToCurrentDocumentStore(bufferedEvents)
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
            configurationNeedsBootstrap = false
        }

        if let depth = pendingPreferredDepth {
            guard await applyPreferredDepthNow(depth, expectedPageEpoch: expectedPageEpoch) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
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
            if pendingDocumentRequest == request {
                pendingDocumentRequest = nil
            }
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
        return .init(epoch: nextEpoch, generation: generation)
    }

    private func drainTransitionFlushIfNeeded(resetCompletedGeneration: Bool = true) async {
        discardedMutationGeneration = max(
            discardedMutationGeneration,
            await mutationPipeline.cancelAndDrainFlushIfNeeded(
                resetCompletedGeneration: resetCompletedGeneration
            )
        )
    }

    private func completeTransition(_ transition: TransitionContext, resumeBootstrap: Bool = true) {
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
            guard pageEpoch == expectedPageEpoch, currentRequestScope === requestScope else {
                needsFrontendDocumentRequestDrain = true
                _ = await dispatchRejectDocumentRequestToFrontend(
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID
                )
                return true
            }
            guard await dispatchFullSnapshotToFrontend(
                payload,
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
            if let snapshot = payloadNormalizer.normalizeSnapshot(payload) {
                currentDocumentStore.replaceDocument(with: snapshot)
            }
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func startMatchedStylesRequest(nodeID: Int, selectionEntry: DOMEntry) {
        cancelMatchedStylesRequest()
        matchedStylesRequestCount += 1
        let requestGeneration = matchedStylesRequestCount
        let requestScope = currentRequestScope
        let selectionDocumentScopeID = currentDocumentScope.documentScopeID
        currentDocumentStore.beginMatchedStylesLoading(for: selectionEntry)

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
                self.currentDocumentStore.applyMatchedStyles(payload, for: currentSelection)
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
                self.currentDocumentStore.clearMatchedStyles(for: currentSelection)
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

    func startSelectorPathRequest(nodeID: Int, selectionEntry: DOMEntry) {
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
                self.currentDocumentStore.applySelectorPath(selectorPath, for: currentSelection)
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
                self.currentDocumentStore.applySelectorPath("", for: currentSelection)
                return
            }
        }
    }

    func cancelSelectorPathRequest() {
        selectorPathTask?.cancel()
        selectorPathTask = nil
    }

    func applySelectionDelta(_ delta: DOMGraphDelta) {
        switch delta {
        case let .selection(selectionPayload):
            currentDocumentStore.applySelectionSnapshot(selectionPayload)
        case let .selectorPath(selectorPayload):
            currentDocumentStore.applySelectorPath(selectorPayload)
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

    func currentSelectedEntry(nodeID: Int, documentScopeID: UInt64) -> DOMEntry? {
        guard currentDocumentScope.documentScopeID == documentScopeID,
              let selectedEntry = currentDocumentStore.selectedEntry,
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
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            await self.requestDocument(
                depth: requestedDepth,
                mode: mode,
                expectedPageEpoch: expectedPageEpoch
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
                    self.currentDocumentStore.applyMutationBundle(
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
            currentDocumentStore.replaceDocument(with: snapshot)
        case let .mutations(bundle):
            applyMutationBundleAcrossDocumentUpdates(bundle)
            if bundle.events.contains(where: Self.isStructuralMutationEvent),
               let selectedEntry = currentDocumentStore.selectedEntry,
               let nodeID = selectedEntry.backendNodeID {
                startSelectorPathRequest(nodeID: nodeID, selectionEntry: selectedEntry)
            }
        case let .replaceSubtree(root):
            currentDocumentStore.applyMutationBundle(.init(events: [.replaceSubtree(root: root)]))
            if let selectedEntry = currentDocumentStore.selectedEntry,
               let nodeID = selectedEntry.backendNodeID {
                startSelectorPathRequest(nodeID: nodeID, selectionEntry: selectedEntry)
            }
        case let .selection(selection):
            currentDocumentStore.applySelectionSnapshot(selection)
        case let .selectorPath(selector):
            currentDocumentStore.applySelectorPath(selector)
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
            entry: DOMEntry,
            preview: String,
            path: [String],
            attributes: [DOMAttribute],
            styleRevision: Int
        )? = currentDocumentStore.selectedEntry.map {
            (
                entry: $0,
                preview: $0.preview,
                path: $0.path,
                attributes: $0.attributes,
                styleRevision: $0.styleRevision
            )
        }
        applySelectionDelta(payloadNormalizer.normalizeSelectionPayload(payload))
        guard let selected = currentDocumentStore.selectedEntry else {
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

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }

    func testWaitForReconcileForTesting() async {}

    func testResetInspectorStateForTesting() {
        resetInspectorState()
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

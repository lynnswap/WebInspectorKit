import Observation
import OSLog
import WebInspectorEngine
import WebInspectorBridge
import WebKit

private let inspectorLogger = Logger(subsystem: "WebInspectorKit", category: "DOMFrontendStore")

@MainActor
@Observable
final class DOMFrontendStore: NSObject {
    private enum HandlerName: String, CaseIterable {
        case protocolMessage = "webInspectorProtocol"
        case ready = "webInspectorReady"
        case log = "webInspectorLog"
        case domSelection = "webInspectorDomSelection"
        case domSelector = "webInspectorDomSelector"
    }

    private struct PendingReconcileWork {
        let shouldApplyConfiguration: Bool
        let preferredDepth: Int?
        let documentRequest: (depth: Int, preserveState: Bool)?
        let shouldFlushMutationBundles: Bool

        var hasWork: Bool {
            shouldApplyConfiguration
                || preferredDepth != nil
                || documentRequest != nil
                || shouldFlushMutationBundles
        }
    }

    let session: DOMSession
    private(set) var webView: InspectorWebView?
    private var isReady = false
    private let mutationPipeline: DOMMutationPipeline
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: (depth: Int, preserveState: Bool)?
    private var configuration: DOMConfiguration
    private var configurationNeedsApply = false
    private var matchedStylesTask: Task<Void, Never>?
    private var matchedStylesRequestCount = 0
#if DEBUG
    private var matchedStylesFetchOverride: (@MainActor (Int) async throws -> DOMMatchedStylesPayload)?
#endif
    private var pendingWorkTask: Task<Void, Never>?
    private var isRunningPendingStateLoop = false
    private var protocolWorkTask: Task<Void, Never>?
    private let protocolRouter: DOMProtocolRouter
    private let payloadNormalizer = DOMPayloadNormalizer()
    private let bridgeRuntime = WISPIRuntime.shared
    var onRecoverableError: (@MainActor (String) -> Void)?

    init(session: DOMSession) {
        self.session = session
        configuration = session.configuration
        mutationPipeline = DOMMutationPipeline(
            session: session,
            bridgeRuntime: bridgeRuntime,
            configuration: session.configuration
        )
        protocolRouter = DOMProtocolRouter(session: session)
        super.init()
        session.bundleSink = self
    }

    func makeInspectorWebView() -> InspectorWebView {
        if let webView {
            attachInspectorWebView()
            mutationPipeline.attachWebView(webView)
            return webView
        }

        let newWebView = InspectorWebView()

        webView = newWebView
        attachInspectorWebView()
        mutationPipeline.attachWebView(newWebView)
        loadInspector(in: newWebView)
        return newWebView
    }

    func detachInspectorWebView() {
        guard let webView else { return }
        detachInspectorWebView(ifMatches: webView)
        resetInspectorState()
        mutationPipeline.attachWebView(nil)
        self.webView = nil
    }

    func enqueueMutationBundle(_ bundle: Any, preserveState: Bool) {
        mutationPipeline.enqueueMutationBundle(bundle, preserveState: preserveState)
    }

    func clearPendingMutationBundles() {
        mutationPipeline.clearPendingMutationBundles()
    }

    var pendingMutationBundleCount: Int {
        mutationPipeline.pendingMutationBundleCount
    }

    func setPreferredDepth(_ depth: Int) async {
        pendingPreferredDepth = depth
        await reconcilePendingStateIfReady()
    }

    func requestDocument(depth: Int, preserveState: Bool) async {
        pendingDocumentRequest = (depth, preserveState)
        await reconcilePendingStateIfReady()
    }

    func updateConfiguration(_ configuration: DOMConfiguration) async {
        self.configuration = configuration
        configurationNeedsApply = true
        mutationPipeline.updateConfiguration(configuration)
        await reconcilePendingStateIfReady()
    }

    private func applyConfigurationToInspector() async {
        guard let webView else { return }
        let config = configuration
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.updateConfig?.(config)",
                arguments: [
                    "config": [
                        "snapshotDepth": config.snapshotDepth,
                        "subtreeDepth": config.subtreeDepth,
                        "autoUpdateDebounce": config.autoUpdateDebounce,
                    ],
                ],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("apply config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func attachInspectorWebView() {
        guard let webView else { return }

        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
            controller.add(self, name: $0.rawValue)
        }
        webView.navigationDelegate = self
    }

    private func detachInspectorWebView(ifMatches webView: InspectorWebView) {
        guard self.webView === webView else { return }
        detachMessageHandlers(from: webView)
    }

    private func resetInspectorState() {
        cancelMatchedStylesRequest()
        pendingWorkTask?.cancel()
        pendingWorkTask = nil
        protocolWorkTask?.cancel()
        protocolWorkTask = nil
        isReady = false
        configurationNeedsApply = false
        mutationPipeline.reset()
        pendingPreferredDepth = nil
        pendingDocumentRequest = nil
    }

    private func detachMessageHandlers(from webView: InspectorWebView) {
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
        }
        webView.navigationDelegate = nil
        inspectorLogger.debug("detached inspector message handlers")
    }

    private func loadInspector(in webView: InspectorWebView) {
        guard
            let mainURL = WIAssets.mainFileURL,
            let baseURL = WIAssets.resourcesDirectory
        else {
            inspectorLogger.error("missing inspector resources")
            return
        }
        isReady = false
        mutationPipeline.setReady(false)
        webView.loadFileURL(mainURL, allowingReadAccessTo: baseURL)
    }

    isolated deinit {
        cancelMatchedStylesRequest()
        pendingWorkTask?.cancel()
        protocolWorkTask?.cancel()
        mutationPipeline.reset()
        if let webView {
            detachMessageHandlers(from: webView)
        }
    }

    private func applyPreferredDepthNow(_ depth: Int) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.setPreferredDepth?.(depth)",
                arguments: ["depth": depth],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("send preferred depth failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestDocumentNow(depth: Int, preserveState: Bool) async {
        guard let webView else { return }
        if !preserveState {
            payloadNormalizer.resetForDocumentUpdate()
            session.graphStore.resetForDocumentUpdate()
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.requestDocument?.(options)",
                arguments: ["options": ["depth": depth, "preserveState": preserveState]],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension DOMFrontendStore: DOMBundleSink {
    func domDidEmit(bundle: DOMBundle) {
        switch bundle.payload {
        case let .jsonString(rawJSON):
            if let delta = payloadNormalizer.normalizeBundlePayload(rawJSON) {
                applyGraphDelta(delta)
            }
            enqueueMutationBundle(rawJSON, preserveState: true)
        case let .objectEnvelope(object):
            if let delta = payloadNormalizer.normalizeBundlePayload(object) {
                applyGraphDelta(delta)
            }
            enqueueMutationBundle(object, preserveState: true)
        }
    }
}

extension DOMFrontendStore: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName = HandlerName(rawValue: message.name) else { return }

        switch handlerName {
        case .protocolMessage:
            handleProtocolPayload(message.body)
        case .ready:
            handleReadyMessage()
        case .log:
            handleLogMessage(message.body)
        case .domSelection:
            handleDOMSelectionMessage(message.body)
        case .domSelector:
            handleDOMSelectorMessage(message.body)
        }
    }
}

private extension DOMFrontendStore {
    private func handleReadyMessage() {
        isReady = true
        configurationNeedsApply = true
        mutationPipeline.setReady(true)
        schedulePendingStateReconcile()
    }

    private func handleLogMessage(_ payload: Any) {
        if let dictionary = payload as? NSDictionary,
           let logMessage = dictionary["message"] as? String {
            inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
        } else if let logMessage = payload as? String {
            inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
        }
    }

    private func handleDOMSelectionMessage(_ payload: Any) {
        let previousSelectedSnapshot: (
            id: DOMEntryID,
            preview: String,
            path: [String],
            attributes: [DOMAttribute],
            styleRevision: Int
        )? = session.graphStore.selectedEntry.map {
            (
                id: $0.id,
                preview: $0.preview,
                path: $0.path,
                attributes: $0.attributes,
                styleRevision: $0.styleRevision
            )
        }
        applyGraphDelta(payloadNormalizer.normalizeSelectionPayload(payload))
        guard let selected = session.graphStore.selectedEntry else {
            cancelMatchedStylesRequest()
            return
        }

        guard let nodeID = selected.backendNodeID else {
            return
        }

        let didSelectNewNode = previousSelectedSnapshot?.id != selected.id
        let didStyleRelevantSnapshotChange = !didSelectNewNode && (
            previousSelectedSnapshot?.preview != selected.preview
                || previousSelectedSnapshot?.path != selected.path
                || previousSelectedSnapshot?.attributes != selected.attributes
                || previousSelectedSnapshot?.styleRevision != selected.styleRevision
        )
        let shouldRefetchForCurrentNode = !selected.isLoadingMatchedStyles
            && selected.matchedStyles.isEmpty
        if didSelectNewNode || didStyleRelevantSnapshotChange || shouldRefetchForCurrentNode {
            startMatchedStylesRequest(nodeID: nodeID, selectionID: selected.id)
        }
    }

    private func handleDOMSelectorMessage(_ payload: Any) {
        if let delta = payloadNormalizer.normalizeSelectorPayload(payload) {
            applyGraphDelta(delta)
        }
    }

    private func reconcilePendingStateIfReady() async {
        schedulePendingStateReconcile()
        guard isRunningPendingStateLoop == false else {
            return
        }
        await pendingWorkTask?.value
    }

    private func schedulePendingStateReconcile() {
        guard pendingWorkTask == nil else {
            return
        }
        pendingWorkTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.runPendingStateLoop()
        }
    }

    private func runPendingStateLoop() async {
        isRunningPendingStateLoop = true
        defer {
            isRunningPendingStateLoop = false
            pendingWorkTask = nil
            if isReady, hasPendingReconcileWork() {
                schedulePendingStateReconcile()
            }
        }

        while isReady {
            let work = takePendingReconcileWork()
            guard work.hasWork else {
                return
            }
            await applyPendingReconcileWork(work)
            if Task.isCancelled {
                return
            }
        }
    }

    private func hasPendingReconcileWork() -> Bool {
        configurationNeedsApply
            || pendingPreferredDepth != nil
            || pendingDocumentRequest != nil
            || pendingMutationBundleCount > 0
    }

    private func startMatchedStylesRequest(nodeID: Int, selectionID: DOMEntryID) {
        cancelMatchedStylesRequest()
        matchedStylesRequestCount += 1
        let requestGeneration = matchedStylesRequestCount
        session.graphStore.beginMatchedStylesLoading(for: selectionID.localID)

        matchedStylesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.fetchMatchedStyles(nodeID: nodeID)
                if Task.isCancelled {
                    return
                }
                guard self.isCurrentMatchedStylesRequest(
                    generation: requestGeneration,
                    selectionID: selectionID
                ) else {
                    return
                }
                self.session.graphStore.applyMatchedStyles(payload, for: selectionID.localID)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                guard self.isCurrentMatchedStylesRequest(
                    generation: requestGeneration,
                    selectionID: selectionID
                ) else {
                    return
                }
                self.session.graphStore.clearMatchedStyles(for: selectionID.localID)
                inspectorLogger.debug("matched styles fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func fetchMatchedStyles(nodeID: Int) async throws -> DOMMatchedStylesPayload {
#if DEBUG
        if let matchedStylesFetchOverride {
            return try await matchedStylesFetchOverride(nodeID)
        }
#endif
        return try await session.matchedStyles(nodeId: nodeID)
    }

    private func isCurrentMatchedStylesRequest(generation: Int, selectionID: DOMEntryID) -> Bool {
        matchedStylesRequestCount == generation
            && session.graphStore.selectedEntry?.id == selectionID
    }

    private func cancelMatchedStylesRequest() {
        matchedStylesTask?.cancel()
        matchedStylesTask = nil
    }

    private func handleProtocolPayload(_ payload: Any?) {
        let method = protocolRequestMethod(from: payload)
        let resetDocumentHint = protocolRequestWantsDocumentReset(method: method, from: payload)
        let previousTask = protocolWorkTask
        protocolWorkTask = Task.immediateIfAvailable { [weak self, previousTask] in
            await previousTask?.value
            guard let self else { return }
            guard Task.isCancelled == false else {
                return
            }
            await self.processProtocolPayload(
                payload,
                method: method,
                resetDocumentHint: resetDocumentHint
            )
        }
    }

    private func takePendingReconcileWork() -> PendingReconcileWork {
        let work = PendingReconcileWork(
            shouldApplyConfiguration: configurationNeedsApply,
            preferredDepth: pendingPreferredDepth,
            documentRequest: pendingDocumentRequest,
            shouldFlushMutationBundles: pendingMutationBundleCount > 0
        )
        configurationNeedsApply = false
        pendingPreferredDepth = nil
        pendingDocumentRequest = nil
        return work
    }

    private func applyPendingReconcileWork(_ work: PendingReconcileWork) async {
        if work.shouldApplyConfiguration {
            await applyConfigurationToInspector()
            if Task.isCancelled {
                return
            }
        }

        if let preferredDepth = work.preferredDepth {
            await applyPreferredDepthNow(preferredDepth)
            if Task.isCancelled {
                return
            }
        }

        if let documentRequest = work.documentRequest {
            await requestDocumentNow(
                depth: documentRequest.depth,
                preserveState: documentRequest.preserveState
            )
            if Task.isCancelled {
                return
            }
        }

        if work.shouldFlushMutationBundles {
            await mutationPipeline.flushPendingBundlesNow()
        }
    }

    private func processProtocolPayload(
        _ payload: Any?,
        method: String?,
        resetDocumentHint: Bool
    ) async {
        let outcome = await protocolRouter.route(payload: payload, configuration: configuration)
        guard Task.isCancelled == false else {
            return
        }

        if let recoverableError = outcome.recoverableError {
            onRecoverableError?(recoverableError)
        }

        if let responseObject = outcome.responseObject {
            if let method,
               let delta = payloadNormalizer.normalizeProtocolResponse(
                method: method,
                responseObject: responseObject,
                resetDocument: resetDocumentHint
               ) {
                applyGraphDelta(delta)
            }
            guard Task.isCancelled == false else {
                return
            }
            let delivered = await dispatchToFrontend(message: responseObject)
            if delivered {
                return
            }

            let fallbackJSON = outcome.responseJSON
                ?? protocolRouter.fallbackJSONResponse(forObjectResponse: responseObject)
            guard let responseJSON = fallbackJSON else {
                return
            }
            inspectorLogger.debug("retrying protocol response dispatch with JSON fallback")
            _ = await dispatchToFrontend(message: responseJSON)
            return
        }

        guard let responseJSON = outcome.responseJSON else {
            return
        }
        guard Task.isCancelled == false else {
            return
        }
        _ = await dispatchToFrontend(message: responseJSON)
    }

    private func applyGraphDelta(_ delta: DOMGraphDelta) {
        switch delta {
        case let .snapshot(snapshot, resetDocument):
            if resetDocument {
                session.graphStore.resetForDocumentUpdate()
            }
            session.graphStore.applySnapshot(snapshot)

        case let .mutations(bundle):
            session.graphStore.applyMutationBundle(bundle)

        case let .replaceSubtree(root):
            session.graphStore.applyMutationBundle(
                .init(events: [.replaceSubtree(root: root)])
            )

        case let .selection(selectionPayload):
            session.graphStore.applySelectionSnapshot(selectionPayload)

        case let .selectorPath(selectorPayload):
            session.graphStore.applySelectorPath(selectorPayload)
        }
    }

    private func protocolRequestMethod(from payload: Any?) -> String? {
        guard let payload else {
            return nil
        }

        if let dictionary = payload as? [String: Any] {
            return dictionary["method"] as? String
        }
        if let dictionary = payload as? NSDictionary {
            return dictionary["method"] as? String
        }
        if let string = payload as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return dictionary["method"] as? String
        }
        return nil
    }

    private func protocolRequestWantsDocumentReset(method: String?, from payload: Any?) -> Bool {
        guard method == "DOM.getDocument",
              let payload
        else {
            return false
        }

        let dictionary: [String: Any]?
        if let direct = payload as? [String: Any] {
            dictionary = direct
        } else if let nsDirect = payload as? NSDictionary {
            dictionary = nsDirect as? [String: Any]
        } else if let string = payload as? String,
                  let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let decoded = object as? [String: Any] {
            dictionary = decoded
        } else {
            dictionary = nil
        }

        guard let dictionary else {
            return true
        }

        guard let rawParams = dictionary["params"] else {
            return true
        }

        let params: [String: Any]
        if let direct = rawParams as? [String: Any] {
            params = direct
        } else if let nsDirect = rawParams as? NSDictionary,
                  let bridged = nsDirect as? [String: Any] {
            params = bridged
        } else {
            return true
        }

        let preserveState: Bool?
        if let boolValue = params["preserveState"] as? Bool {
            preserveState = boolValue
        } else if let number = params["preserveState"] as? NSNumber {
            preserveState = number.boolValue
        } else {
            preserveState = nil
        }
        guard let preserveState else {
            return true
        }
        return preserveState == false
    }

    @discardableResult
    private func dispatchToFrontend(message: Any) async -> Bool {
        guard let webView else { return true }
        do {
            try await webView.callAsyncVoidJavaScript(
                """
                (function(message) {
                    let resolved = message;
                    if (typeof resolved === "string") {
                        try {
                            window.webInspectorDOMFrontend?.dispatchMessageFromBackend?.(JSON.parse(resolved));
                            return;
                        } catch {
                        }
                    }
                    window.webInspectorDOMFrontend?.dispatchMessageFromBackend?.(resolved);
                })(message);
                """,
                arguments: ["message": message],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch to frontend failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

extension DOMFrontendStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        inspectorLogger.error("inspector navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        inspectorLogger.error("inspector load failed: \(error.localizedDescription, privacy: .public)")
    }
}

#if DEBUG
extension DOMFrontendStore {
    var testBundleFlushInterval: TimeInterval {
        mutationPipeline.currentBundleFlushInterval
    }

    var testHasPendingBundleFlushTask: Bool {
        mutationPipeline.hasPendingBundleFlushTask
    }

    func testSetReady(_ ready: Bool) {
        isReady = ready
        mutationPipeline.setReady(ready)
    }

    var testMatchedStylesRequestToken: Int {
        matchedStylesRequestCount
    }

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }

    var testMatchedStylesFetcher: (@MainActor (Int) async throws -> DOMMatchedStylesPayload)? {
        get { matchedStylesFetchOverride }
        set { matchedStylesFetchOverride = newValue }
    }

    func testProtocolRequestWantsDocumentReset(method: String?, payload: Any?) -> Bool {
        protocolRequestWantsDocumentReset(method: method, from: payload)
    }
}
#endif

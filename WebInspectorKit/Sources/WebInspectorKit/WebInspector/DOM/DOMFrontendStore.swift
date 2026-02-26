import Observation
import OSLog
import WebInspectorKitCore
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

    let session: DOMSession
    private(set) var webView: InspectorWebView?
    private var isReady = false
    private let mutationPipeline: DOMMutationPipeline
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: (depth: Int, preserveState: Bool)?
    private var configuration: DOMConfiguration
    private var matchedStylesTask: Task<Void, Never>?
    private var matchedStylesRequestToken = 0
    private let protocolRouter: DOMProtocolRouter
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

    func setPreferredDepth(_ depth: Int) {
        pendingPreferredDepth = depth
        if isReady {
            Task {
                await applyPreferredDepthNow(depth)
            }
        }
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        pendingDocumentRequest = (depth, preserveState)
        if isReady {
            Task {
                await requestDocumentNow(depth: depth, preserveState: preserveState)
            }
        }
    }

    func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
        mutationPipeline.updateConfiguration(configuration)
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
        isReady = false
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
            enqueueMutationBundle(rawJSON, preserveState: true)
        case let .objectEnvelope(object):
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
        mutationPipeline.setReady(true)
        Task {
            await applyConfigurationToInspector()
            await flushPendingWork()
        }
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
        if let dictionary = payload as? NSDictionary, dictionary.count > 0 {
            let previousNodeId = session.selection.nodeId
            let previousPreview = session.selection.preview
            let previousPath = session.selection.path
            let previousAttributes = session.selection.attributes
            let previousStyleRevision = session.selection.styleRevision
            session.selection.applySnapshot(from: dictionary)
            if let nodeId = session.selection.nodeId {
                let didSelectNewNode = previousNodeId != nodeId
                let didStyleRelevantSnapshotChange = !didSelectNewNode && (
                    previousPreview != session.selection.preview
                        || previousPath != session.selection.path
                        || previousAttributes != session.selection.attributes
                        || previousStyleRevision != session.selection.styleRevision
                )
                let shouldRefetchForCurrentNode = !session.selection.isLoadingMatchedStyles
                    && session.selection.matchedStyles.isEmpty
                if didSelectNewNode || didStyleRelevantSnapshotChange || shouldRefetchForCurrentNode {
                    startMatchedStylesRequest(nodeId: nodeId)
                }
            } else {
                cancelMatchedStylesRequest()
                session.selection.clearMatchedStyles()
            }
        } else {
            cancelMatchedStylesRequest()
            session.selection.clear()
        }
    }

    private func handleDOMSelectorMessage(_ payload: Any) {
        if let dictionary = payload as? NSDictionary {
            let nodeId = dictionary["id"] as? Int
            let selectorPath = dictionary["selectorPath"] as? String ?? ""
            if let nodeId, session.selection.nodeId == nodeId {
                session.selection.selectorPath = selectorPath
            }
        }
    }

    private func flushPendingWork() async {
        if let preferredDepth = pendingPreferredDepth {
            await applyPreferredDepthNow(preferredDepth)
            pendingPreferredDepth = nil
        }
        if let request = pendingDocumentRequest {
            await requestDocumentNow(depth: request.depth, preserveState: request.preserveState)
            pendingDocumentRequest = nil
        }
        await mutationPipeline.flushPendingBundlesNow()
    }

    private func startMatchedStylesRequest(nodeId: Int) {
        cancelMatchedStylesRequest()
        let requestToken = matchedStylesRequestToken
        session.selection.beginMatchedStylesLoading(for: nodeId)

        matchedStylesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let payload = try await self.session.matchedStyles(nodeId: nodeId)
                guard !Task.isCancelled else { return }
                guard requestToken == self.matchedStylesRequestToken else { return }
                guard self.session.selection.nodeId == nodeId else { return }
                self.session.selection.applyMatchedStyles(payload, for: nodeId)
            } catch {
                guard !Task.isCancelled else { return }
                guard requestToken == self.matchedStylesRequestToken else { return }
                guard self.session.selection.nodeId == nodeId else { return }
                self.session.selection.clearMatchedStyles()
                inspectorLogger.debug("matched styles fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func cancelMatchedStylesRequest() {
        matchedStylesTask?.cancel()
        matchedStylesTask = nil
        matchedStylesRequestToken += 1
    }

    private func handleProtocolPayload(_ payload: Any?) {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await protocolRouter.route(payload: payload, configuration: configuration)
            if let recoverableError = outcome.recoverableError {
                onRecoverableError?(recoverableError)
            }
            if let responseObject = outcome.responseObject {
                let delivered = await dispatchToFrontend(message: responseObject)
                if delivered {
                    return
                }

                let fallbackJSON = outcome.responseJSON
                    ?? protocolRouter.fallbackJSONResponse(forObjectResponse: responseObject)
                guard let responseJSON = fallbackJSON else { return }
                inspectorLogger.debug("retrying protocol response dispatch with JSON fallback")
                _ = await dispatchToFrontend(message: responseJSON)
                return
            }
            guard let responseJSON = outcome.responseJSON else { return }
            _ = await dispatchToFrontend(message: responseJSON)
        }
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
        matchedStylesRequestToken
    }

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }
}
#endif

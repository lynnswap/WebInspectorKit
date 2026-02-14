import WebKit
import OSLog
import Observation
import WebInspectorKitCore

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

    private struct InspectorProtocolRequest {
        let id: Int
        let method: String
        let params: [String: Any]
    }

    private struct PendingBundle {
        let rawJSON: String
        let preserveState: Bool
    }

    let session: DOMSession
    private(set) var webView: InspectorWebView?
    private var isReady = false
    private var pendingBundles: [PendingBundle] = []
    private var pendingBundleFlushTask: Task<Void, Never>?
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: (depth: Int, preserveState: Bool)?
    private var configuration: DOMConfiguration
    private var matchedStylesTask: Task<Void, Never>?
    private var matchedStylesRequestToken = 0

    init(session: DOMSession) {
        self.session = session
        self.configuration = session.configuration
        super.init()
        session.bundleSink = self
    }

    func makeInspectorWebView() -> InspectorWebView {
        if let webView {
            attachInspectorWebView()
            return webView
        }

        let newWebView = InspectorWebView()

        webView = newWebView
        attachInspectorWebView()
        loadInspector(in: newWebView)
        return newWebView
    }

    func detachInspectorWebView() {
        guard let webView else { return }
        detachInspectorWebView(ifMatches: webView)
        resetInspectorState()
        self.webView = nil
    }

    func enqueueMutationBundle(_ rawJSON: String, preserveState: Bool) {
        let payload = PendingBundle(rawJSON: rawJSON, preserveState: preserveState)
        applyMutationBundle(payload)
    }

    func clearPendingMutationBundles() {
        pendingBundles.removeAll()
        cancelPendingBundleFlush()
    }

    var pendingMutationBundleCount: Int {
        pendingBundles.count
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
                        "autoUpdateDebounce": config.autoUpdateDebounce
                    ]
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
        pendingBundles.removeAll()
        cancelPendingBundleFlush()
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
        webView.loadFileURL(mainURL, allowingReadAccessTo: baseURL)
    }

    @MainActor deinit {
        cancelMatchedStylesRequest()
        if let webView {
            detachMessageHandlers(from: webView)
        }
    }

    private func applyMutationBundle(_ payload: PendingBundle) {
        pendingBundles.append(payload)
        if isReady {
            schedulePendingBundleFlush()
        }
    }

    private func bundleFlushInterval() -> TimeInterval {
        let baseInterval = configuration.autoUpdateDebounce / 4
        return max(0.05, min(0.2, baseInterval))
    }

    private func schedulePendingBundleFlush() {
        guard pendingBundleFlushTask == nil else { return }
        let interval = bundleFlushInterval()
        pendingBundleFlushTask = Task { @MainActor in
            let delay = UInt64(interval * 1_000_000_000)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            await flushPendingBundlesNow()
        }
    }

    private func flushPendingBundlesNow() async {
        pendingBundleFlushTask?.cancel()
        pendingBundleFlushTask = nil
        guard isReady else { return }
        let bundles = pendingBundles
        pendingBundles.removeAll()
        if bundles.isEmpty {
            return
        }
        await applyBundlesNow(bundles)
    }

    private func cancelPendingBundleFlush() {
        pendingBundleFlushTask?.cancel()
        pendingBundleFlushTask = nil
    }

    private func applyBundlesNow(_ bundles: [PendingBundle]) async {
        guard let webView, !bundles.isEmpty else { return }
        do {
            let payloads = bundles.map { ["bundle": $0.rawJSON, "preserveState": $0.preserveState] }
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applyMutationBundles?.(bundles)",
                arguments: ["bundles": payloads],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("send mutation bundles failed: \(error.localizedDescription, privacy: .public)")
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
        enqueueMutationBundle(bundle.rawJSON, preserveState: true)
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
        Task {
            await applyConfigurationToInspector()
            await flushPendingWork()
        }
    }

    private func handleLogMessage(_ payload: Any) {
        if let dictionary = payload as? [String: Any],
           let logMessage = dictionary["message"] as? String {
            inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
        } else if let logMessage = payload as? String {
            inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
        }
    }

    private func handleDOMSelectionMessage(_ payload: Any) {
        if let dictionary = payload as? [String: Any], !dictionary.isEmpty {
            let previousNodeId = session.selection.nodeId
            let previousPreview = session.selection.preview
            let previousPath = session.selection.path
            let previousAttributes = session.selection.attributes
            session.selection.applySnapshot(from: dictionary)
            if let nodeId = session.selection.nodeId {
                let didSelectNewNode = previousNodeId != nodeId
                let didStyleRelevantSnapshotChange = !didSelectNewNode && (
                    previousPreview != session.selection.preview
                        || previousPath != session.selection.path
                        || previousAttributes != session.selection.attributes
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
        if let dictionary = payload as? [String: Any] {
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
        await flushPendingBundlesNow()
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
        var object: [String: Any]?
        if let messageString = payload as? String, let data = messageString.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else if let dictionary = payload as? [String: Any] {
            object = dictionary
        }
        guard
            let dictionary = object,
            let id = protocolRequestID(from: dictionary["id"]),
            let method = dictionary["method"] as? String
        else {
            return
        }
        let params = dictionary["params"] as? [String: Any] ?? [:]
        let request = InspectorProtocolRequest(id: id, method: method, params: params)
        processProtocolRequest(request)
    }

    private func protocolRequestID(from value: Any?) -> Int? {
        switch value {
        case let id as Int:
            return id
        case let number as NSNumber:
            // JS numbers often arrive bridged as NSNumber. Avoid truncating non-integral values.
            let doubleValue = number.doubleValue
            let intValue = number.intValue
            guard Double(intValue) == doubleValue else { return nil }
            return intValue
        case let double as Double:
            let intValue = Int(double)
            guard Double(intValue) == double else { return nil }
            return intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func processProtocolRequest(_ request: InspectorProtocolRequest) {
        Task {
            do {
                switch request.method {
                case "DOM.getDocument":
                    let depth = (request.params["depth"] as? Int) ?? configuration.snapshotDepth
                    let payload = try await self.session.captureSnapshot(maxDepth: depth)
                    await self.sendResponse(id: request.id, result: payload)
                case "DOM.requestChildNodes":
                    let depth = (request.params["depth"] as? Int) ?? configuration.subtreeDepth
                    let identifier = request.params["nodeId"] as? Int ?? 0
                    let subtree = try await self.session.captureSubtree(nodeId: identifier, maxDepth: depth)
                    await self.sendResponse(id: request.id, result: subtree)
                case "DOM.highlightNode":
                    if let identifier = request.params["nodeId"] as? Int {
                        await self.session.highlight(nodeId: identifier)
                    }
                    await self.sendResponse(id: request.id, result: [:])
                case "Overlay.hideHighlight", "DOM.hideHighlight":
                    await self.session.hideHighlight()
                    await self.sendResponse(id: request.id, result: [:])
                case "DOM.getSelectorPath":
                    let identifier = request.params["nodeId"] as? Int ?? 0
                    let selectorPath = try await self.session.selectorPath(nodeId: identifier)
                    await self.sendResponse(id: request.id, result: ["selectorPath": selectorPath])
                default:
                    await self.sendError(id: request.id, message: "Unsupported method: \(request.method)")
                }
            } catch {
                await self.sendError(id: request.id, message: error.localizedDescription)
            }
        }
    }

    private func dispatchToFrontend(_ message: Any) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.dispatchMessageFromBackend?.(message)",
                arguments: ["message": message],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("dispatch to frontend failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendResponse(id: Int, result: Any) async {
        var message: [String: Any] = ["id": id]
        message["result"] = result
        await dispatchToFrontend(message)
    }

    private func sendError(id: Int, message: String) async {
        let payload: [String: Any] = [
            "id": id,
            "error": ["message": message]
        ]
        await dispatchToFrontend(payload)
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
        bundleFlushInterval()
    }

    var testHasPendingBundleFlushTask: Bool {
        pendingBundleFlushTask != nil
    }

    func testSetReady(_ ready: Bool) {
        isReady = ready
    }

    var testMatchedStylesRequestToken: Int {
        matchedStylesRequestToken
    }

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }
}
#endif

import Observation
import OSLog
import WebInspectorEngine
import WebInspectorScripts
import WebKit

private let inspectorLogger = Logger(subsystem: "WebInspectorKit", category: "DOMFrontendStore")

@MainActor
@Observable
final class DOMFrontendStore: NSObject {
    private struct FrontendBootstrapState {
        let readyState: String
        let hasFrontend: Bool
        let hasProtocolHandler: Bool
    }

    private struct FrontendAssetState {
        let readyState: String
        let stylesheetCount: Int
        let hasLinkedDOMTreeStylesheet: Bool
        let hasInlineFallbackStylesheet: Bool
        let backgroundColor: String
    }

    private struct ProtocolRequestContext {
        let id: Int
        let method: String
        let nodeID: Int?
        let documentGeneration: UInt64

        var isDocumentGenerationBound: Bool {
            method == "DOM.getDocument"
                || method == "DOM.requestChildNodes"
                || method == "DOM.getSelectorPath"
        }
    }

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
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: (depth: Int, preserveState: Bool)?
    private var pendingProtocolEvents: [[String: Any]] = []
    private var configuration: DOMConfiguration
    private let protocolRouter: DOMProtocolRouter
    private let payloadNormalizer = DOMPayloadNormalizer()

    var onRecoverableError: (@MainActor (String) -> Void)?

    init(session: DOMSession) {
        self.session = session
        configuration = session.configuration
        protocolRouter = DOMProtocolRouter(session: session)
        super.init()
        session.eventSink = self
    }

    var hasInspectorWebView: Bool {
        webView != nil
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
        guard let webView else {
            return
        }
        detachInspectorWebView(ifMatches: webView)
        resetInspectorState()
        self.webView = nil
    }

    func setPreferredDepth(_ depth: Int) {
        pendingPreferredDepth = depth
        guard isReady else {
            return
        }
        Task {
            await applyPreferredDepthNow(depth)
        }
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        pendingDocumentRequest = (depth, preserveState)
        guard isReady else {
            return
        }
        Task {
            await requestDocumentNow(depth: depth, preserveState: preserveState)
        }
    }

    func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
    }

    private func applyConfigurationToInspector() async {
        guard let webView else {
            return
        }

        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.updateConfig?.(config)",
                arguments: [
                    "config": [
                        "snapshotDepth": configuration.rootBootstrapDepth,
                        "subtreeDepth": configuration.expandedSubtreeFetchDepth,
                        "autoUpdateDebounce": configuration.autoUpdateDebounce,
                    ],
                ],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("apply config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func attachInspectorWebView() {
        guard let webView else {
            return
        }

        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
            controller.add(self, name: $0.rawValue)
        }
        webView.navigationDelegate = self
    }

    private func detachInspectorWebView(ifMatches webView: InspectorWebView) {
        guard self.webView === webView else {
            return
        }
        detachMessageHandlers(from: webView)
    }

    private func resetInspectorState() {
        isReady = false
        pendingPreferredDepth = nil
        pendingDocumentRequest = nil
        pendingProtocolEvents.removeAll(keepingCapacity: false)
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
            let readAccessURL = WIAssets.resourcesReadAccessURL
        else {
            inspectorLogger.error("missing inspector resources")
            return
        }

        isReady = false
        inspectorLogger.notice(
            "loading inspector resources html=\(mainURL.path(percentEncoded: false), privacy: .public) readAccess=\(readAccessURL.path(percentEncoded: false), privacy: .public)"
        )
        webView.loadFileURL(mainURL, allowingReadAccessTo: readAccessURL)
    }

    isolated deinit {
        if let webView {
            detachMessageHandlers(from: webView)
        }
    }

    private func applyPreferredDepthNow(_ depth: Int) async {
        guard let webView else {
            return
        }
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
        guard let webView else {
            return
        }

        inspectorLogger.notice(
            "requesting frontend document depth=\(depth, privacy: .public) preserveState=\(preserveState, privacy: .public)"
        )
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

extension DOMFrontendStore: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName = HandlerName(rawValue: message.name) else {
            return
        }

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
    func handleReadyMessage() {
        guard !isReady else {
            return
        }
        isReady = true
        inspectorLogger.notice("dom frontend ready")
        Task {
            await applyConfigurationToInspector()
            let didRequestDocument = await flushPendingWork()
            if didRequestDocument == false, session.hasPageWebView {
                let preserveState = session.graphStore.rootID != nil
                await requestDocumentNow(
                    depth: preserveState ? configuration.fullReloadDepth : configuration.rootBootstrapDepth,
                    preserveState: preserveState
                )
            }
        }
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
        applyFrontendSelectionPayload(payloadNormalizer.selectionPayload(from: payload))
        guard let selected = session.graphStore.selectedEntry else {
            return
        }

        let nodeID = selected.id.nodeID

        let didSelectNewNode = previousSelectedSnapshot?.id != selected.id
        let didStyleRelevantSnapshotChange = !didSelectNewNode && (
            previousSelectedSnapshot?.preview != selected.preview
                || previousSelectedSnapshot?.path != selected.path
                || previousSelectedSnapshot?.attributes != selected.attributes
                || previousSelectedSnapshot?.styleRevision != selected.styleRevision
        )
        if didSelectNewNode || didStyleRelevantSnapshotChange {
            inspectorLogger.notice(
                "frontend selection updated nodeId=\(nodeID, privacy: .public); matched styles refresh is delegated to WIDOMModel"
            )
        }
    }

    func handleDOMSelectorMessage(_ payload: Any) {
        if let selectorPayload = payloadNormalizer.selectorPayload(from: payload) {
            applyFrontendSelectorPayload(selectorPayload)
        }
    }

    func flushPendingWork() async -> Bool {
        var didRequestDocument = false

        if let preferredDepth = pendingPreferredDepth {
            await applyPreferredDepthNow(preferredDepth)
            pendingPreferredDepth = nil
        }

        if let request = pendingDocumentRequest {
            await requestDocumentNow(depth: request.depth, preserveState: request.preserveState)
            pendingDocumentRequest = nil
            didRequestDocument = true
            if !pendingProtocolEvents.isEmpty {
                inspectorLogger.notice(
                    "dropping \(self.pendingProtocolEvents.count, privacy: .public) buffered DOM protocol event(s) after document reload request"
                )
                pendingProtocolEvents.removeAll(keepingCapacity: true)
            }
        }

        if !didRequestDocument, !pendingProtocolEvents.isEmpty {
            let events = pendingProtocolEvents
            pendingProtocolEvents.removeAll(keepingCapacity: true)
            for event in events {
                _ = await dispatchToFrontend(message: event)
            }
        }

        return didRequestDocument
    }

    func handleProtocolPayload(_ payload: Any?) {
        let requestContext = protocolRequestContext(from: payload)
        let method = requestContext?.method
        Task { [weak self] in
            guard let self else {
                return
            }
            if let method {
                inspectorLogger.notice("routing DOM protocol method \(method, privacy: .public)")
            }
            let outcome = await protocolRouter.route(payload: payload, configuration: configuration)
            if let recoverableError = outcome.recoverableError {
                onRecoverableError?(recoverableError)
            }
            if let requestContext,
               requestContext.isDocumentGenerationBound,
               let staleResponse = staleProtocolResponseIfNeeded(for: requestContext) {
                inspectorLogger.notice(
                    "dropping stale DOM response for \(requestContext.method, privacy: .public) node=\(String(describing: requestContext.nodeID), privacy: .public) generation=\(requestContext.documentGeneration, privacy: .public) current=\(self.session.graphStore.documentGeneration, privacy: .public)"
                )
                await requestFreshDocumentAfterStaleNodeResponse()
                _ = await dispatchToFrontend(message: staleResponse)
                return
            }
            if let responseObject = outcome.responseObject {
                // Transport-backed sessions own the authoritative graph; protocol responses only feed the frontend.
                let delivered = await dispatchToFrontend(message: responseObject)
                if delivered {
                    if let method {
                        inspectorLogger.notice("delivered DOM response to frontend for \(method, privacy: .public)")
                    }
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
            _ = await dispatchToFrontend(message: responseJSON)
        }
    }

    func applyFrontendSelectionPayload(_ selectionPayload: DOMSelectionSnapshotPayload?) {
        session.graphStore.applySelectionSnapshot(selectionPayload)
    }

    func applyFrontendSelectorPayload(_ selectorPayload: DOMSelectorPathPayload) {
        session.graphStore.applySelectorPath(selectorPayload)
    }

    private func frontendBootstrapState(in webView: WKWebView) async -> FrontendBootstrapState? {
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return {
                    readyState: document.readyState,
                    hasFrontend: !!window.webInspectorDOMFrontend?.__installed,
                    hasProtocolHandler: !!window.webkit?.messageHandlers?.webInspectorProtocol
                }
                """,
                arguments: [:],
                contentWorld: .page
            )
            guard let dictionary = result as? [String: Any] else {
                return nil
            }
            return FrontendBootstrapState(
                readyState: dictionary["readyState"] as? String ?? "unknown",
                hasFrontend: dictionary["hasFrontend"] as? Bool ?? false,
                hasProtocolHandler: dictionary["hasProtocolHandler"] as? Bool ?? false
            )
        } catch {
            inspectorLogger.error("inspect frontend bootstrap failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func frontendAssetState(in webView: WKWebView) async -> FrontendAssetState? {
        do {
            let result = try await webView.callAsyncJavaScript(
                """
                return {
                    readyState: document.readyState,
                    stylesheetCount: document.styleSheets.length,
                    hasLinkedDOMTreeStylesheet: Array.from(document.styleSheets).some((sheet) => {
                        const href = sheet.href || "";
                        return href.includes("dom-tree-view.css");
                    }),
                    hasInlineFallbackStylesheet: !!document.getElementById("wi-dom-tree-inline-style"),
                    backgroundColor: window.getComputedStyle(document.body).backgroundColor
                }
                """,
                arguments: [:],
                contentWorld: .page
            )
            guard let dictionary = result as? [String: Any] else {
                return nil
            }
            return FrontendAssetState(
                readyState: dictionary["readyState"] as? String ?? "unknown",
                stylesheetCount: dictionary["stylesheetCount"] as? Int ?? 0,
                hasLinkedDOMTreeStylesheet: dictionary["hasLinkedDOMTreeStylesheet"] as? Bool ?? false,
                hasInlineFallbackStylesheet: dictionary["hasInlineFallbackStylesheet"] as? Bool ?? false,
                backgroundColor: dictionary["backgroundColor"] as? String ?? "unknown"
            )
        } catch {
            inspectorLogger.error("inspect frontend asset state failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func installFallbackFrontendBootstrapIfNeeded(in webView: WKWebView) async {
        guard let state = await frontendBootstrapState(in: webView), state.hasFrontend == false else {
            return
        }

        inspectorLogger.notice(
            "reinstalling DOM frontend bootstrap readyState=\(state.readyState, privacy: .public) handler=\(state.hasProtocolHandler, privacy: .public)"
        )

        do {
            let scriptSource = try WebInspectorScripts.domTreeView()
            try await webView.callAsyncVoidJavaScript(
                """
                (0, eval)(source);
                """,
                arguments: ["source": scriptSource],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("fallback frontend bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func ensureFrontendStylesheetIfNeeded(in webView: WKWebView) async {
        guard let assetState = await frontendAssetState(in: webView) else {
            return
        }

        if assetState.hasLinkedDOMTreeStylesheet || assetState.hasInlineFallbackStylesheet {
            inspectorLogger.notice(
                "frontend stylesheet ready readyState=\(assetState.readyState, privacy: .public) count=\(assetState.stylesheetCount, privacy: .public) linked=\(assetState.hasLinkedDOMTreeStylesheet, privacy: .public) inline=\(assetState.hasInlineFallbackStylesheet, privacy: .public) background=\(assetState.backgroundColor, privacy: .public)"
            )
            return
        }

        inspectorLogger.notice(
            "injecting inline DOM stylesheet readyState=\(assetState.readyState, privacy: .public) count=\(assetState.stylesheetCount, privacy: .public)"
        )

        do {
            let stylesheetSource = try WIAssets.stylesheetSource()
            try await webView.callAsyncVoidJavaScript(
                """
                if (!document.getElementById(styleID)) {
                    const style = document.createElement("style");
                    style.id = styleID;
                    style.textContent = source;
                    document.head.appendChild(style);
                }
                """,
                arguments: [
                    "styleID": "wi-dom-tree-inline-style",
                    "source": stylesheetSource,
                ],
                contentWorld: .page
            )
        } catch {
            inspectorLogger.error("inline stylesheet injection failed: \(error.localizedDescription, privacy: .public)")
        }

        if let hydratedState = await frontendAssetState(in: webView) {
            inspectorLogger.notice(
                "frontend stylesheet state after recovery count=\(hydratedState.stylesheetCount, privacy: .public) linked=\(hydratedState.hasLinkedDOMTreeStylesheet, privacy: .public) inline=\(hydratedState.hasInlineFallbackStylesheet, privacy: .public) background=\(hydratedState.backgroundColor, privacy: .public)"
            )
        }
    }

    func recoverFrontendIfNeeded(for webView: WKWebView) async {
        await installFallbackFrontendBootstrapIfNeeded(in: webView)
        await ensureFrontendStylesheetIfNeeded(in: webView)

        if let state = await frontendBootstrapState(in: webView) {
            inspectorLogger.notice(
                "frontend bootstrap state readyState=\(state.readyState, privacy: .public) frontend=\(state.hasFrontend, privacy: .public) handler=\(state.hasProtocolHandler, privacy: .public)"
            )
            guard state.hasFrontend, state.hasProtocolHandler else {
                return
            }
            handleReadyMessage()
        }
    }

    func prepareForFrontendReloadIfNeeded() {
        guard isReady else {
            return
        }

        isReady = false
        if pendingDocumentRequest == nil, session.graphStore.rootID != nil {
            pendingDocumentRequest = (
                depth: configuration.fullReloadDepth,
                preserveState: true
            )
        }
    }

    func protocolRequestMethod(from payload: Any?) -> String? {
        protocolRequestContext(from: payload)?.method
    }

    private func protocolRequestContext(from payload: Any?) -> ProtocolRequestContext? {
        guard let dictionary = protocolRequestDictionary(from: payload) else {
            return nil
        }
        guard let method = dictionary["method"] as? String else {
            return nil
        }
        guard let identifier = parseProtocolIdentifier(dictionary["id"]) else {
            return nil
        }

        let params = dictionary["params"] as? [String: Any]
        let nodeID = params?["nodeId"] as? Int
            ?? params?["parentNodeId"] as? Int
            ?? params?["parentId"] as? Int
        return ProtocolRequestContext(
            id: identifier,
            method: method,
            nodeID: nodeID,
            documentGeneration: session.graphStore.documentGeneration
        )
    }

    func protocolRequestDictionary(from payload: Any?) -> [String: Any]? {
        guard let payload else {
            return nil
        }

        if let dictionary = payload as? [String: Any] {
            return dictionary
        }
        if let dictionary = payload as? NSDictionary {
            return dictionary as? [String: Any]
        }
        if let string = payload as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        return nil
    }

    func parseProtocolIdentifier(_ value: Any?) -> Int? {
        switch value {
        case is Bool:
            return nil
        case let intValue as Int:
            return intValue
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite else {
                return nil
            }
            let truncated = doubleValue.rounded(.towardZero)
            guard truncated == doubleValue else {
                return nil
            }
            guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
                return nil
            }
            return Int(truncated)
        case let stringValue as String:
            return Int(stringValue)
        case let doubleValue as Double where doubleValue.isFinite:
            let truncated = doubleValue.rounded(.towardZero)
            guard truncated == doubleValue else {
                return nil
            }
            guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
                return nil
            }
            return Int(truncated)
        default:
            return nil
        }
    }

    private func staleProtocolResponseIfNeeded(for context: ProtocolRequestContext) -> [String: Any]? {
        let nodeIsMissingFromCurrentDocument: Bool
        if let nodeID = context.nodeID {
            nodeIsMissingFromCurrentDocument = session.graphStore.entry(forNodeID: nodeID) == nil
        } else {
            nodeIsMissingFromCurrentDocument = false
        }

        guard context.documentGeneration != session.graphStore.documentGeneration
            || nodeIsMissingFromCurrentDocument else {
            return nil
        }

        switch context.method {
        case "DOM.getDocument":
            return makeCurrentDocumentResponse(id: context.id)
        case "DOM.requestChildNodes":
            return ["id": context.id, "result": NSNull()]
        case "DOM.getSelectorPath":
            return ["id": context.id, "result": ["selectorPath": ""]]
        default:
            return nil
        }
    }

    func makeCurrentDocumentResponse(id: Int) -> [String: Any]? {
        guard let rootID = session.graphStore.rootID,
              let rootEntry = session.graphStore.entry(for: rootID) else {
            return ["id": id, "result": [:]]
        }

        var result: [String: Any] = [
            "root": serializedNode(from: rootEntry)
        ]
        if let selectedNodeID = session.graphStore.selectedEntry?.id.nodeID {
            result["selectedNodeId"] = selectedNodeID
        }
        return ["id": id, "result": result]
    }

    func serializedNode(from entry: DOMEntry) -> [String: Any] {
        var node: [String: Any] = [
            "nodeId": entry.id.nodeID,
            "nodeType": entry.nodeType,
            "nodeName": entry.nodeName,
            "localName": entry.localName,
            "nodeValue": entry.nodeValue,
            "childNodeCount": entry.childCount,
        ]
        if !entry.attributes.isEmpty {
            node["attributes"] = entry.attributes.flatMap { [$0.name, $0.value] }
        }
        if !entry.layoutFlags.isEmpty {
            node["layoutFlags"] = entry.layoutFlags
        }
        if !entry.children.isEmpty {
            node["children"] = entry.children.map(serializedNode(from:))
        }
        return node
    }

    func requestFreshDocumentAfterStaleNodeResponse() async {
        let preserveState = session.graphStore.rootID != nil
        let refreshDepth = preserveState
            ? configuration.fullReloadDepth
            : configuration.rootBootstrapDepth

        pendingDocumentRequest = (
            depth: refreshDepth,
            preserveState: preserveState
        )
        guard isReady else {
            return
        }
        await requestDocumentNow(
            depth: refreshDepth,
            preserveState: preserveState
        )
        pendingDocumentRequest = nil
    }

    @discardableResult
    func dispatchToFrontend(message: Any) async -> Bool {
        guard let webView else {
            return true
        }
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

extension DOMFrontendStore: DOMProtocolEventSink {
    func domDidReceiveProtocolEvent(method: String, paramsData: Data) {
        let paramsObject: Any
        if let object = try? JSONSerialization.jsonObject(with: paramsData) {
            paramsObject = object
        } else {
            paramsObject = [:] as [String: Any]
        }

        let message: [String: Any] = [
            "method": method,
            "params": paramsObject,
        ]

        guard webView != nil else {
            return
        }

        if !isReady {
            pendingProtocolEvents.append(message)
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            _ = await dispatchToFrontend(message: message)
        }
    }
}

extension DOMFrontendStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let currentWebView = self.webView, currentWebView === webView else {
            return
        }

        prepareForFrontendReloadIfNeeded()

        Task { [weak self] in
            guard let self else {
                return
            }
            await recoverFrontendIfNeeded(for: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        inspectorLogger.error("inspector navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        inspectorLogger.error("inspector load failed: \(error.localizedDescription, privacy: .public)")
    }
}

#if DEBUG
extension DOMFrontendStore {
    func testSetReady(_ ready: Bool) {
        isReady = ready
    }

    var testIsReady: Bool {
        isReady
    }

    var testPendingDocumentRequest: (depth: Int, preserveState: Bool)? {
        pendingDocumentRequest
    }

    var testPendingProtocolEventCount: Int {
        pendingProtocolEvents.count
    }

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }

    func testPrepareForFrontendReloadIfNeeded() {
        prepareForFrontendReloadIfNeeded()
    }

    func testSetPendingDocumentRequest(depth: Int, preserveState: Bool) {
        pendingDocumentRequest = (depth, preserveState)
    }

    func testSetPendingProtocolEvents(_ events: [[String: Any]]) {
        pendingProtocolEvents = events
    }

    func testFlushPendingWork() async -> Bool {
        await flushPendingWork()
    }

    func testHandleProtocolPayload(_ payload: Any?) async {
        handleProtocolPayload(payload)
        await Task.yield()
        await Task.yield()
    }

    func testRequestFreshDocumentAfterStaleNodeResponse() async {
        await requestFreshDocumentAfterStaleNodeResponse()
    }

    func testParseProtocolIdentifier(_ value: Any?) -> Int? {
        parseProtocolIdentifier(value)
    }

    func testMakeCurrentDocumentResponse(id: Int) -> [String: Any]? {
        makeCurrentDocumentResponse(id: id)
    }

    func testStaleProtocolResponseIfNeeded(
        id: Int,
        method: String,
        nodeID: Int?,
        documentGeneration: UInt64
    ) -> [String: Any]? {
        staleProtocolResponseIfNeeded(
            for: .init(
                id: id,
                method: method,
                nodeID: nodeID,
                documentGeneration: documentGeneration
            )
        )
    }
}
#endif

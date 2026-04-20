import Foundation
import OSLog
import WebKit

#if canImport(AppKit)
import AppKit
#endif

private let domInspectorBridgeLogger = Logger(subsystem: "WebInspectorKit", category: "DOMInspectorBridge")

@MainActor
final class DOMInspectorBridge: NSObject {
    enum IncomingMessage {
        case ready(contextID: DOMContextID)
        case requestChildren(nodeID: Int, depth: Int, contextID: DOMContextID)
        case highlight(nodeID: Int, reveal: Bool, contextID: DOMContextID)
        case hideHighlight(contextID: DOMContextID)
        case domSelection(payload: Any, contextID: DOMContextID)
        case log(String)
    }

    private enum HandlerName: String, CaseIterable {
        case requestChildren = "webInspectorDomRequestChildren"
        case highlight = "webInspectorDomHighlight"
        case hideHighlight = "webInspectorDomHideHighlight"
        case ready = "webInspectorReady"
        case log = "webInspectorLog"
        case domSelection = "webInspectorDomSelection"
    }

    var onMessage: (@MainActor (IncomingMessage) -> Void)?

    private(set) var inspectorWebView: InspectorWebView?
    private var bootstrapPayload: [String: Any] = DOMInspectorBridge.defaultBootstrapPayload()

    func makeInspectorWebView(bootstrapPayload: [String: Any]) -> InspectorWebView {
        self.bootstrapPayload = bootstrapPayload
        if let inspectorWebView {
            attachInspectorWebView(to: inspectorWebView)
            applyBootstrap(on: inspectorWebView)
            return inspectorWebView
        }

        let inspectorWebView = InspectorWebView()
        installInitialBootstrap(on: inspectorWebView)
        attachInspectorWebView(to: inspectorWebView)
        loadInspector(in: inspectorWebView)
        self.inspectorWebView = inspectorWebView
        return inspectorWebView
    }

    func updateBootstrap(_ bootstrapPayload: [String: Any]) {
        self.bootstrapPayload = bootstrapPayload
        guard let inspectorWebView else {
            return
        }
        applyBootstrap(on: inspectorWebView)
    }

    func detachInspectorWebView() {
        guard let inspectorWebView else {
            return
        }
        detachMessageHandlers(from: inspectorWebView)
        self.inspectorWebView = nil
    }

    func applyFullSnapshot(_ payload: Any, contextID: DOMContextID) async {
        await evaluateVoidPreservingViewport(
            "window.webInspectorDOMFrontend?.applyFullSnapshot?.(payload, contextID)",
            arguments: [
                "payload": payload,
                "contextID": contextID,
            ]
        )
    }

    func applyMutationBundles(_ payload: Any, contextID: DOMContextID) async {
        await evaluateVoidPreservingViewport(
            "window.webInspectorDOMFrontend?.applyMutationBundles?.(payload, contextID)",
            arguments: [
                "payload": payload,
                "contextID": contextID,
            ]
        )
    }

    func applySubtreePayload(_ payload: Any, contextID: DOMContextID) async {
        await evaluateVoidPreservingViewport(
            "window.webInspectorDOMFrontend?.applySubtreePayload?.(payload, contextID)",
            arguments: [
                "payload": payload,
                "contextID": contextID,
            ]
        )
    }

    func applySelectionPayload(_ payload: Any, contextID: DOMContextID) async {
        await evaluateVoidPreservingViewport(
            "window.webInspectorDOMFrontend?.applySelectionPayload?.(payload, contextID)",
            arguments: [
                "payload": payload,
                "contextID": contextID,
            ]
        )
    }

    func finishChildNodeRequest(nodeID: Int, success: Bool, contextID: DOMContextID) async {
        await evaluateVoidPreservingViewport(
            "window.webInspectorDOMFrontend?.finishChildNodeRequest?.(nodeId, success, contextID)",
            arguments: [
                "nodeId": nodeID,
                "success": success,
                "contextID": contextID,
            ]
        )
    }

    func clearPointerHoverState() async {
        await evaluateVoid(
            "window.webInspectorDOMFrontend?.clearPointerHoverState?.()",
            arguments: [:]
        )
    }

#if canImport(AppKit)
    func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        inspectorWebView?.domContextMenuProvider = provider
    }
#endif
}

private extension DOMInspectorBridge {
    static func defaultBootstrapPayload() -> [String: Any] {
        [
            "config": [
                "snapshotDepth": 4,
                "subtreeDepth": 3,
                "autoUpdateDebounce": 0.6,
            ],
            "context": [
                "contextID": 0,
            ],
        ]
    }

    func attachInspectorWebView(to inspectorWebView: InspectorWebView) {
        let controller = inspectorWebView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
            controller.add(self, name: $0.rawValue)
        }
        inspectorWebView.navigationDelegate = self
    }

    func detachMessageHandlers(from inspectorWebView: InspectorWebView) {
        let controller = inspectorWebView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
        }
        inspectorWebView.navigationDelegate = nil
    }

    func installInitialBootstrap(on inspectorWebView: InspectorWebView) {
        let controller = inspectorWebView.configuration.userContentController
        let bootstrapJSON = serializedBootstrapJSON()
        controller.addUserScript(
            WKUserScript(
                source: "window.__wiDOMFrontendBootstrap = \(bootstrapJSON);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    func applyBootstrap(on inspectorWebView: InspectorWebView) {
        let bootstrapJSON = serializedBootstrapJSON()
        inspectorWebView.evaluateJavaScript(
            """
            window.__wiDOMFrontendBootstrap = \(bootstrapJSON);
            window.webInspectorDOMFrontend?.updateBootstrap?.(window.__wiDOMFrontendBootstrap);
            """
        )
    }

    func serializedBootstrapJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: bootstrapPayload),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    func loadInspector(in inspectorWebView: InspectorWebView) {
        guard let mainURL = WIAssets.mainFileURL,
              let baseURL = WIAssets.resourcesDirectory
        else {
            domInspectorBridgeLogger.error("missing inspector resources")
            return
        }
        inspectorWebView.loadFileURL(mainURL, allowingReadAccessTo: baseURL)
    }

    func evaluateVoid(_ script: String, arguments: [String: Any]) async {
        guard let inspectorWebView else {
            return
        }
        do {
            try await inspectorWebView.callAsyncVoidJavaScript(
                script,
                arguments: arguments,
                contentWorld: .page
            )
        } catch {
            domInspectorBridgeLogger.error("bridge dispatch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func evaluateVoidPreservingViewport(_ script: String, arguments: [String: Any]) async {
        guard let inspectorWebView else {
            return
        }
        do {
#if canImport(UIKit)
            try await inspectorWebView.callAsyncVoidJavaScriptPreservingViewport(
                script,
                arguments: arguments,
                contentWorld: .page
            )
#else
            try await inspectorWebView.callAsyncVoidJavaScript(
                script,
                arguments: arguments,
                contentWorld: .page
            )
#endif
        } catch {
            domInspectorBridgeLogger.error("bridge dispatch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func parseInt(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    func parseBool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func parseContextID(_ value: Any?) -> DOMContextID? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? NSNumber, value.intValue >= 0 {
            return value.uint64Value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? String {
            return UInt64(value)
        }
        return nil
    }

    func dictionaryPayload(from body: Any) -> [String: Any]? {
        if let dictionary = body as? [String: Any] {
            return dictionary
        }
        if let dictionary = body as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }
}

extension DOMInspectorBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handler = HandlerName(rawValue: message.name) else {
            return
        }
        let body = message.body
        switch handler {
        case .ready:
            let contextID = dictionaryPayload(from: body).flatMap { parseContextID($0["contextID"]) } ?? 0
            onMessage?(.ready(contextID: contextID))
        case .requestChildren:
            guard let payload = dictionaryPayload(from: body),
                  let nodeID = parseInt(payload["nodeId"]),
                  let depth = parseInt(payload["depth"])
            else {
                return
            }
            let contextID = parseContextID(payload["contextID"]) ?? 0
            onMessage?(.requestChildren(nodeID: nodeID, depth: depth, contextID: contextID))
        case .highlight:
            guard let payload = dictionaryPayload(from: body),
                  let nodeID = parseInt(payload["nodeId"])
            else {
                return
            }
            let reveal = parseBool(dictionaryPayload(from: body)?["reveal"]) ?? true
            let contextID = parseContextID(dictionaryPayload(from: body)?["contextID"]) ?? 0
            onMessage?(.highlight(nodeID: nodeID, reveal: reveal, contextID: contextID))
        case .hideHighlight:
            let contextID = dictionaryPayload(from: body).flatMap { parseContextID($0["contextID"]) } ?? 0
            onMessage?(.hideHighlight(contextID: contextID))
        case .domSelection:
            let payload = dictionaryPayload(from: body) ?? [:]
            let contextID = parseContextID(payload["contextID"]) ?? 0
            onMessage?(.domSelection(payload: body, contextID: contextID))
        case .log:
            if let payload = dictionaryPayload(from: body), let message = payload["message"] as? String {
                onMessage?(.log(message))
            } else if let message = body as? String {
                onMessage?(.log(message))
            }
        }
    }
}

extension DOMInspectorBridge: WKNavigationDelegate {}

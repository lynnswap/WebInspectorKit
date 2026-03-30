import Foundation
import OSLog
import WebKit

#if canImport(AppKit)
import AppKit
#endif

private let domInspectorBridgeLogger = Logger(subsystem: "WebInspectorKit", category: "DOMInspectorBridge")

@MainActor
final class DOMInspectorBridge: NSObject {
    enum HandlerName: String, CaseIterable {
        case requestDocument = "webInspectorDomRequestDocument"
        case requestChildren = "webInspectorDomRequestChildren"
        case highlight = "webInspectorDomHighlight"
        case hideHighlight = "webInspectorDomHideHighlight"
        case ready = "webInspectorReady"
        case log = "webInspectorLog"
        case domSelection = "webInspectorDomSelection"
    }

    weak var runtime: DOMInspectorRuntime?
    private(set) var inspectorWebView: InspectorWebView?

    func makeInspectorWebView() -> InspectorWebView {
        if let inspectorWebView {
            attachInspectorWebView(to: inspectorWebView)
            return inspectorWebView
        }

        let newWebView = InspectorWebView()
        installInitialBootstrap(on: newWebView)
        inspectorWebView = newWebView
        attachInspectorWebView(to: newWebView)
        loadInspector(in: newWebView)
        return newWebView
    }

    func detachInspectorWebView() {
        guard let inspectorWebView else {
            return
        }
        detachInspectorWebView(ifMatches: inspectorWebView)
        self.inspectorWebView = nil
    }

#if canImport(AppKit)
    func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        inspectorWebView?.domContextMenuProvider = provider
    }
#endif

    private func attachInspectorWebView(to inspectorWebView: InspectorWebView) {
        let controller = inspectorWebView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
            controller.add(self, name: $0.rawValue)
        }
        inspectorWebView.navigationDelegate = self
    }

    private func installInitialBootstrap(on inspectorWebView: InspectorWebView) {
        let controller = inspectorWebView.configuration.userContentController
        let bootstrapPayload = runtime?.currentBootstrapPayload ?? [
            "config": [
                "pageEpoch": runtime?.currentPageEpoch ?? 0,
            ],
        ]
        let bootstrapData = try? JSONSerialization.data(withJSONObject: bootstrapPayload)
        let bootstrapJSON = bootstrapData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pageEpoch = runtime?.currentPageEpoch ?? 0
        controller.addUserScript(
            WKUserScript(
                source: """
                window.__wiDOMFrontendInitialPageEpoch = \(pageEpoch);
                window.__wiDOMFrontendBootstrap = \(bootstrapJSON);
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    private func detachInspectorWebView(ifMatches inspectorWebView: InspectorWebView) {
        guard self.inspectorWebView === inspectorWebView else {
            return
        }
        detachMessageHandlers(from: inspectorWebView)
    }

    private func detachMessageHandlers(from inspectorWebView: InspectorWebView) {
        let controller = inspectorWebView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
        }
        inspectorWebView.navigationDelegate = nil
        domInspectorBridgeLogger.debug("detached inspector message handlers")
    }

    private func loadInspector(in inspectorWebView: InspectorWebView) {
        guard
            let mainURL = WIAssets.mainFileURL,
            let baseURL = WIAssets.resourcesDirectory
        else {
            domInspectorBridgeLogger.error("missing inspector resources")
            return
        }
        inspectorWebView.loadFileURL(mainURL, allowingReadAccessTo: baseURL)
    }

    func refreshBootstrapPayloadIfPossible() {
        guard let inspectorWebView else {
            return
        }
        applyLatestBootstrapPayload(on: inspectorWebView)
    }

    private func applyLatestBootstrapPayload(on inspectorWebView: InspectorWebView) {
        let bootstrapPayload = runtime?.currentBootstrapPayload ?? [
            "config": [
                "pageEpoch": runtime?.currentPageEpoch ?? 0,
            ],
        ]
        guard let bootstrapData = try? JSONSerialization.data(withJSONObject: bootstrapPayload),
              let bootstrapJSON = String(data: bootstrapData, encoding: .utf8)
        else {
            return
        }
        let pageEpoch = runtime?.currentPageEpoch ?? 0
        inspectorWebView.evaluateJavaScript(
            """
            window.__wiDOMFrontendInitialPageEpoch = \(pageEpoch);
            window.__wiDOMFrontendBootstrap = \(bootstrapJSON);
            if (window.webInspectorDOMFrontend?.updateConfig) {
                const config = window.__wiDOMFrontendBootstrap?.config;
                if (config && typeof config === "object") {
                    window.webInspectorDOMFrontend.updateConfig(config);
                }
            }
            """
        )
    }

    private func readPageEpoch(from payload: Any?) -> Int? {
        if let dictionary = payload as? [String: Any] {
            return parsePageEpochValue(dictionary["pageEpoch"])
        }
        if let dictionary = payload as? NSDictionary {
            return parsePageEpochValue(dictionary["pageEpoch"])
        }
        if let string = payload as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return parsePageEpochValue(dictionary["pageEpoch"])
        }
        return nil
    }

    private func readDocumentScopeID(from payload: Any?) -> UInt64? {
        if let dictionary = payload as? [String: Any] {
            return parseUnsignedIntegerValue(dictionary["documentScopeID"])
        }
        if let dictionary = payload as? NSDictionary {
            return parseUnsignedIntegerValue(dictionary["documentScopeID"])
        }
        if let string = payload as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return parseUnsignedIntegerValue(dictionary["documentScopeID"])
        }
        return nil
    }

    private func readNodeID(from payload: Any?) -> Int? {
        if let dictionary = payload as? [String: Any] {
            return parseIntegerValue(dictionary["nodeId"])
        }
        if let dictionary = payload as? NSDictionary {
            return parseIntegerValue(dictionary["nodeId"])
        }
        if let string = payload as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            return parseIntegerValue(dictionary["nodeId"])
        }
        return nil
    }

    private func parsePageEpochValue(_ value: Any?) -> Int? {
        parseIntegerValue(value)
    }

    private func parseIntegerValue(_ value: Any?) -> Int? {
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

    private func parseUnsignedIntegerValue(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber, value.intValue >= 0 {
            return value.uint64Value
        }
        if let value = value as? String, let parsed = UInt64(value) {
            return parsed
        }
        return nil
    }
}

extension DOMInspectorBridge: DOMBundleSink {
    func domDidEmit(bundle: DOMBundle) {
        runtime?.handleDOMBundle(bundle)
    }
}

extension DOMInspectorBridge: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName = HandlerName(rawValue: message.name) else {
            return
        }
        handleMessage(handlerName, body: message.body)
    }
}

private extension DOMInspectorBridge {
    func handleMessage(_ handlerName: HandlerName, body: Any) {
        let pageEpoch = readPageEpoch(from: body)
        let documentScopeID = readDocumentScopeID(from: body)
        switch handlerName {
        case .requestDocument:
            guard runtime?.acceptsFrontendMessage(pageEpoch: pageEpoch, documentScopeID: documentScopeID) == true else {
                runtime?.handleRejectedDocumentRequestMessage(
                    pageEpoch: pageEpoch,
                    documentScopeID: documentScopeID
                )
                return
            }
            runtime?.handleDocumentRequestMessage(body)
        case .requestChildren:
            guard runtime?.acceptsFrontendMessage(pageEpoch: pageEpoch, documentScopeID: documentScopeID) == true else {
                runtime?.handleRejectedChildNodeRequestMessage(
                    nodeID: readNodeID(from: body),
                    pageEpoch: pageEpoch,
                    documentScopeID: documentScopeID
                )
                return
            }
            runtime?.handleChildNodeRequestMessage(body)
        case .highlight:
            guard runtime?.acceptsFrontendMessage(pageEpoch: pageEpoch, documentScopeID: documentScopeID) == true else {
                return
            }
            runtime?.handleHighlightRequestMessage(body)
        case .hideHighlight:
            guard runtime?.acceptsFrontendMessage(pageEpoch: pageEpoch, documentScopeID: documentScopeID) == true else {
                return
            }
            runtime?.handleHideHighlightRequestMessage(body)
        case .ready:
            guard runtime?.acceptsReadyMessage(pageEpoch: pageEpoch, documentScopeID: documentScopeID) == true else {
                return
            }
            runtime?.handleReadyMessage()
        case .log:
            runtime?.handleLogMessage(body)
        case .domSelection:
            guard runtime?.acceptsFrontendMessage(pageEpoch: pageEpoch, documentScopeID: documentScopeID) == true else {
                return
            }
            runtime?.handleDOMSelectionMessage(body)
        }
    }
}

#if DEBUG
extension DOMInspectorBridge {
    func testHandleMessage(named handlerName: String, body: Any) {
        guard let handlerName = HandlerName(rawValue: handlerName) else {
            return
        }
        handleMessage(handlerName, body: body)
    }
}
#endif

extension DOMInspectorBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let inspectorWebView = webView as? InspectorWebView else {
            return
        }
        applyLatestBootstrapPayload(on: inspectorWebView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        domInspectorBridgeLogger.error("inspector navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        domInspectorBridgeLogger.error("inspector load failed: \(error.localizedDescription, privacy: .public)")
    }
}

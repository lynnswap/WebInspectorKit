//
//  WebInspectorInspectorModel.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import WebKit
import OSLog
import Observation

private let inspectorLogger = Logger(subsystem: "WebInspectorKit", category: "WIInspectorModel")

@MainActor
@Observable
final class WIInspectorModel: NSObject {
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

    weak var bridge: WIBridgeModel?
    private(set) var webView: WIWebView?
    private var isReady = false
    private var pendingBundles: [PendingBundle] = []
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: (depth: Int, preserveState: Bool)?
    private var configuration: WebInspectorModel.Configuration {
        bridge?.configuration ?? .init()
    }
    private func webViewID(_ webView: WKWebView?) -> String {
        guard let webView else { return "nil" }
        return String(Int(bitPattern: UInt(bitPattern: ObjectIdentifier(webView))))
    }

    func makeInspectorWebView() -> WIWebView {
        if let webView {
            inspectorLogger.debug("reuse inspector webView:\(self.webViewID(webView), privacy: .public) isReady:\(self.isReady, privacy: .public)")
            attachInspectorWebView()
            return webView
        }

        let newWebView = WIWebView()

        webView = newWebView
        inspectorLogger.debug("make inspector webView:\(self.webViewID(newWebView), privacy: .public)")
        attachInspectorWebView()
        loadInspector(in: newWebView)
        return newWebView
    }

    func teardownInspectorWebView(_ webView: WIWebView) {
        detachInspectorWebView(ifMatches: webView)
    }

    func detachInspectorWebView() {
        guard let webView else { return }
        detachInspectorWebView(ifMatches: webView)
        resetInspectorState()
        self.webView = nil
    }

    func enqueueMutationBundle(_ rawJSON: String, preserveState: Bool) {
        let payload = PendingBundle(rawJSON: rawJSON, preserveState: preserveState)
        inspectorLogger.debug("enqueueMutationBundle bytes:\(rawJSON.utf8.count, privacy: .public) preserveState:\(preserveState, privacy: .public) isReady:\(self.isReady, privacy: .public)")
        applyMutationBundle(payload)
    }

    func setPreferredDepth(_ depth: Int) {
        pendingPreferredDepth = depth
        inspectorLogger.debug("setPreferredDepth pending depth:\(depth, privacy: .public) isReady:\(self.isReady, privacy: .public)")
        if isReady {
            Task {
                await applyPreferredDepthNow(depth)
            }
        }
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        pendingDocumentRequest = (depth, preserveState)
        inspectorLogger.debug("requestDocument queued depth:\(depth, privacy: .public) preserveState:\(preserveState, privacy: .public) isReady:\(self.isReady, privacy: .public)")
        if isReady {
            Task {
                await requestDocumentNow(depth: depth, preserveState: preserveState)
            }
        }
    }

    private func applyConfigurationToInspector() async {
        guard let webView else { return }
        let config = configuration
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.updateConfig?.(config)",
                arguments: [
                    "config": [
                        "snapshotDepth": config.snapshotDepth,
                        "subtreeDepth": config.subtreeDepth,
                        "autoUpdateDebounce": config.autoUpdateDebounce
                    ]
                ],
                contentWorld: .page
            )
            inspectorLogger.debug("applyConfigurationToInspector success config:\(config.snapshotDepth)-\(config.subtreeDepth)-\(config.autoUpdateDebounce, privacy: .public) webView:\(self.webViewID(webView), privacy: .public)")
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
        inspectorLogger.debug("attached inspector handlers webView:\(self.webViewID(webView), privacy: .public)")
    }

    private func detachInspectorWebView(ifMatches webView: WIWebView) {
        guard self.webView === webView else { return }
        detachMessageHandlers(from: webView)
    }

    private func resetInspectorState() {
        isReady = false
        pendingBundles.removeAll()
        pendingPreferredDepth = nil
        pendingDocumentRequest = nil
    }

    private func detachMessageHandlers(from webView: WIWebView) {
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
        }
        webView.navigationDelegate = nil
        inspectorLogger.debug("detached inspector message handlers webView:\(self.webViewID(webView), privacy: .public)")
    }

    private func loadInspector(in webView: WIWebView) {
        guard
            let mainURL = WIAssets.mainFileURL,
            let baseURL = WIAssets.resourcesDirectory
        else {
            inspectorLogger.error("missing inspector resources")
            return
        }
        isReady = false
        inspectorLogger.debug("loadInspector start base:\(baseURL.absoluteString, privacy: .public)")
        webView.loadFileURL(mainURL, allowingReadAccessTo: baseURL)
    }

    @MainActor deinit {
        if let webView {
            detachMessageHandlers(from: webView)
        }
    }

    private func applyMutationBundle(_ payload: PendingBundle) {
        if isReady {
            Task {
                await applyBundleNow(payload)
            }
        } else {
            inspectorLogger.debug("queue mutation bundle pendingCount:\(self.pendingBundles.count + 1, privacy: .public)")
            pendingBundles.append(payload)
        }
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
            let id = dictionary["id"] as? Int,
            let method = dictionary["method"] as? String
        else {
            return
        }
        inspectorLogger.debug("protocol payload id:\(id, privacy: .public) method:\(method, privacy: .public)")
        let params = dictionary["params"] as? [String: Any] ?? [:]
        let request = InspectorProtocolRequest(id: id, method: method, params: params)
        processProtocolRequest(request)
    }

    private func processProtocolRequest(_ request: InspectorProtocolRequest) {
        Task {
            do {
                switch request.method {
                case "DOM.getDocument":
                    let depth = (request.params["depth"] as? Int) ?? configuration.snapshotDepth
                    guard let content = self.bridge?.contentModel else {
                        throw WIError.scriptUnavailable
                    }
                    let payload = try await content.captureSnapshot(maxDepth: depth)
                    await self.sendResponse(id: request.id, result: payload.rawJSON)
                case "DOM.requestChildNodes":
                    let depth = (request.params["depth"] as? Int) ?? configuration.subtreeDepth
                    let identifier = request.params["nodeId"] as? Int ?? 0
                    guard let content = self.bridge?.contentModel else {
                        throw WIError.scriptUnavailable
                    }
                    let subtree = try await content.captureSubtree(identifier: identifier, maxDepth: depth)
                    await self.sendResponse(id: request.id, result: subtree.rawJSON)
                case "DOM.highlightNode":
                    if let identifier = request.params["nodeId"] as? Int {
                        await self.bridge?.contentModel.highlightDOMNode(id: identifier)
                    }
                    await self.sendResponse(id: request.id, result: [:])
                case "Overlay.hideHighlight", "DOM.hideHighlight":
                    self.bridge?.contentModel.clearWebInspectorHighlight()
                    await self.sendResponse(id: request.id, result: [:])
                case "DOM.getSelectorPath":
                    let identifier = request.params["nodeId"] as? Int ?? 0
                    guard let content = self.bridge?.contentModel else {
                        throw WIError.scriptUnavailable
                    }
                    let selectorPath = try await content.selectionCopyText(for: identifier, kind: .selectorPath)
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
                "window.webInspectorKit?.dispatchMessageFromBackend?.(message)",
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

    private func flushPendingWork() async {
        if let preferredDepth = pendingPreferredDepth {
            await applyPreferredDepthNow(preferredDepth)
            pendingPreferredDepth = nil
        }
        if let request = pendingDocumentRequest {
            await requestDocumentNow(depth: request.depth, preserveState: request.preserveState)
            pendingDocumentRequest = nil
        }
        if !pendingBundles.isEmpty {
            inspectorLogger.debug("flushPendingWork bundles:\(self.pendingBundles.count, privacy: .public)")
            await applyBundlesNow(pendingBundles)
            pendingBundles.removeAll()
        }
    }

    private func applyBundlesNow(_ bundles: [PendingBundle]) async {
        guard let webView, !bundles.isEmpty else { return }
        do {
            let payloads = bundles.map { ["bundle": $0.rawJSON, "preserveState": $0.preserveState] }
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.applyMutationBundles?.(bundles)",
                arguments: ["bundles": payloads],
                contentWorld: .page
            )
            inspectorLogger.debug("applyBundlesNow count:\(bundles.count, privacy: .public) webView:\(self.webViewID(webView), privacy: .public)")
        } catch {
            inspectorLogger.error("send mutation bundles failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyBundleNow(_ payload: PendingBundle) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.applyMutationBundle?.(bundle)",
                arguments: ["bundle": ["bundle": payload.rawJSON, "preserveState": payload.preserveState]],
                contentWorld: .page
            )
            inspectorLogger.debug("applyBundleNow bytes:\(payload.rawJSON.utf8.count, privacy: .public) preserveState:\(payload.preserveState, privacy: .public) webView:\(self.webViewID(webView), privacy: .public)")
        } catch {
            inspectorLogger.error("send mutation bundle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyPreferredDepthNow(_ depth: Int) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.setPreferredDepth?.(depth)",
                arguments: ["depth": depth],
                contentWorld: .page
            )
            inspectorLogger.debug("applyPreferredDepthNow depth:\(depth, privacy: .public) webView:\(self.webViewID(webView), privacy: .public)")
        } catch {
            inspectorLogger.error("send preferred depth failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestDocumentNow(depth: Int, preserveState: Bool) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.requestDocument?.(options)",
                arguments: ["options": ["depth": depth, "preserveState": preserveState]],
                contentWorld: .page
            )
            inspectorLogger.debug("requestDocumentNow depth:\(depth, privacy: .public) preserveState:\(preserveState, privacy: .public) webView:\(self.webViewID(webView), privacy: .public)")
        } catch {
            inspectorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension WIInspectorModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName = HandlerName(rawValue: message.name) else { return }

        switch handlerName {
        case .protocolMessage:
            handleProtocolPayload(message.body)
        case .ready:
            isReady = true
            Task{
                await applyConfigurationToInspector()
                await flushPendingWork()
                bridge?.isLoading = false
            }
            inspectorLogger.debug("inspector ready pendingBundles:\(self.pendingBundles.count, privacy: .public) pendingDoc:\(self.pendingDocumentRequest != nil, privacy: .public) pendingDepth:\(self.pendingPreferredDepth ?? -1, privacy: .public)")
        case .log:
            if let dictionary = message.body as? [String: Any],
               let logMessage = dictionary["message"] as? String {
                inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
            } else if let logMessage = message.body as? String {
                inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
            }
        case .domSelection:
            if let dictionary = message.body as? [String: Any], !dictionary.isEmpty {
                bridge?.domSelection.applySnapshot(from: dictionary)
            } else {
                bridge?.domSelection.clear()
            }
        case .domSelector:
            if let dictionary = message.body as? [String: Any] {
                let nodeId = dictionary["id"] as? Int
                let selectorPath = dictionary["selectorPath"] as? String ?? ""
                if let nodeId, bridge?.domSelection.nodeId == nodeId {
                    bridge?.domSelection.selectorPath = selectorPath
                }
            }
        }
    }
}

extension WIInspectorModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        inspectorLogger.error("inspector navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        inspectorLogger.error("inspector load failed: \(error.localizedDescription, privacy: .public)")
    }
}

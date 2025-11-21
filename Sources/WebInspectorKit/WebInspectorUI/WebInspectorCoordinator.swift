//
//  WebInspectorCoordinator.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import WebKit
import OSLog

private let coordinatorLogger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorCoordinator")

@MainActor
final class WebInspectorCoordinator: NSObject {
    private enum HandlerName: String, CaseIterable {
        case protocolMessage = "webInspectorProtocol"
        case ready = "webInspectorReady"
        case log = "webInspectorLog"
    }

    private struct InspectorProtocolRequest {
        let id: Int
        let method: String
        let params: [String: Any]
    }

    private weak var webView: WKWebView?
    private var isReady = false
    private var pendingBundles: [WebInspectorBridge.PendingBundle] = []
    private var pendingSearchTerm: String?
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: (depth: Int, preserveState: Bool)?
    private weak var bridge: WebInspectorBridge?
    init(bridge: WebInspectorBridge) {
        self.bridge = bridge
        super.init()
    }

    func attach(webView: WKWebView) {
        if self.webView !== webView {
            isReady = false
        }
        self.webView = webView
        
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
            controller.add(self, name: $0.rawValue)
        }
        webView.navigationDelegate = self
    }

    func applyMutationBundle(_ payload: WebInspectorBridge.PendingBundle) {
        if isReady {
            Task{
                await applyBundleNow(payload)
            }
        } else {
            pendingBundles.append(payload)
        }
    }

    func updateSearchTerm(_ term: String) {
        pendingSearchTerm = term
        if isReady {
            Task{
                await applySearchTermNow(term)
            }
        }
    }

    func setPreferredDepth(_ depth: Int) {
        pendingPreferredDepth = depth
        if isReady {
            Task{
                await applyPreferredDepthNow(depth)
            }
        }
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        pendingDocumentRequest = (depth, preserveState)
        if isReady {
            Task{
                await requestDocumentNow(depth: depth, preserveState: preserveState)
            }
        }
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue)
        }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        self.webView = nil
        coordinatorLogger.debug("inspector detached")
    }

    @MainActor deinit {
        if let controller = webView?.configuration.userContentController{
            HandlerName.allCases.forEach {
                controller.removeScriptMessageHandler(forName: $0.rawValue)
            }
        }
        webView?.navigationDelegate = nil
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
        let params = dictionary["params"] as? [String: Any] ?? [:]
        let request = InspectorProtocolRequest(id: id, method: method, params: params)
        processProtocolRequest(request)
    }

    private func processProtocolRequest(_ request: InspectorProtocolRequest) {
        Task {
            do {
                switch request.method {
                case "DOM.getDocument":
                    let depth = (request.params["depth"] as? Int) ?? WebInspectorConstants.defaultDepth
                    guard let content = self.bridge?.contentModel else {
                        throw WebInspectorError.scriptUnavailable
                    }
                    let payload = try await content.captureSnapshot(maxDepth: depth)
                    await self.sendResponse(id: request.id, result: payload.rawJSON)
                case "DOM.requestChildNodes":
                    let depth = (request.params["depth"] as? Int) ?? WebInspectorConstants.subtreeDepth
                    let identifier = request.params["nodeId"] as? Int ?? 0
                    guard let content = self.bridge?.contentModel else {
                        throw WebInspectorError.scriptUnavailable
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
            coordinatorLogger.error("dispatch to frontend failed: \(error.localizedDescription, privacy: .public)")
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
            await applyBundlesNow(pendingBundles)
            pendingBundles.removeAll()
        }
        if let term = pendingSearchTerm {
            await applySearchTermNow(term)
            pendingSearchTerm = nil
        }
    }

    private func applyBundlesNow(_ bundles: [WebInspectorBridge.PendingBundle]) async {
        guard let webView, !bundles.isEmpty else { return }
        do {
            let payloads = bundles.map { ["bundle": $0.rawJSON, "preserveState": $0.preserveState] }
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.applyMutationBundles?.(bundles)",
                arguments: ["bundles": payloads],
                contentWorld: .page
            )
        } catch {
            coordinatorLogger.error("send mutation bundles failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyBundleNow(_ payload: WebInspectorBridge.PendingBundle) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.applyMutationBundle?.(bundle)",
                arguments: ["bundle": ["bundle": payload.rawJSON, "preserveState": payload.preserveState]],
                contentWorld: .page
            )
        } catch {
            coordinatorLogger.error("send mutation bundle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applySearchTermNow(_ term: String) async {
        guard let webView else { return }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit?.setSearchTerm?.(term)",
                arguments: ["term": term],
                contentWorld: .page
            )
        } catch {
            coordinatorLogger.error("send search term failed: \(error.localizedDescription, privacy: .public)")
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
        } catch {
            coordinatorLogger.error("send preferred depth failed: \(error.localizedDescription, privacy: .public)")
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
        } catch {
            coordinatorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeMessageHandlers(from controller: WKUserContentController) {
        HandlerName.allCases.forEach { controller.removeScriptMessageHandler(forName: $0.rawValue) }
    }
}

extension WebInspectorCoordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName = HandlerName(rawValue: message.name) else { return }

        switch handlerName {
        case .protocolMessage:
            handleProtocolPayload(message.body)
        case .ready:
            isReady = true
            Task{
                await flushPendingWork()
                bridge?.isLoading = false
            }
        case .log:
            if let dictionary = message.body as? [String: Any],
               let logMessage = dictionary["message"] as? String {
                coordinatorLogger.debug("inspector log: \(logMessage, privacy: .public)")
            } else if let logMessage = message.body as? String {
                coordinatorLogger.debug("inspector log: \(logMessage, privacy: .public)")
            }
        }
    }
}

extension WebInspectorCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        coordinatorLogger.error("inspector navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        coordinatorLogger.error("inspector load failed: \(error.localizedDescription, privacy: .public)")
    }
}

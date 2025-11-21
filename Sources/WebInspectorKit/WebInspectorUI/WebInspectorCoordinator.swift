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
final class WebInspectorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let handlerName = "webInspector"

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

    func attach(webView: WKWebView, resetReadiness: Bool = true) {
        self.webView = webView
        if resetReadiness {
            isReady = false
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "protocol":
            handleProtocolPayload(body["payload"])
        case "ready":
            isReady = true
            flushPendingWork()
            bridge?.isLoading = false
        case "log":
            if let payload = body["payload"] as? [String: Any], let message = payload["message"] as? String {
                coordinatorLogger.debug("inspector log: \(message, privacy: .public)")
            }
        default:
            break
        }
    }

    func applyMutationBundle(_ payload: WebInspectorBridge.PendingBundle) {
        if isReady {
            applyBundleNow(payload)
        } else {
            pendingBundles.append(payload)
        }
    }

    func updateSearchTerm(_ term: String) {
        pendingSearchTerm = term
        if isReady {
            applySearchTermNow(term)
        }
    }

    func setPreferredDepth(_ depth: Int) {
        pendingPreferredDepth = depth
        if isReady {
            applyPreferredDepthNow(depth)
        }
    }

    func requestDocument(depth: Int, preserveState: Bool) {
        pendingDocumentRequest = (depth, preserveState)
        if isReady {
            requestDocumentNow(depth: depth, preserveState: preserveState)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        coordinatorLogger.error("inspector navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        coordinatorLogger.error("inspector load failed: \(error.localizedDescription, privacy: .public)")
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else { return }
        userContentControllerCleanup()
        self.webView = nil
        coordinatorLogger.debug("inspector detached")
    }

    @MainActor deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView?.navigationDelegate = nil
    }

    private func userContentControllerCleanup() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch request.method {
                case "DOM.getDocument":
                    let depth = (request.params["depth"] as? Int) ?? WebInspectorConstants.defaultDepth
                    guard let content = self.bridge?.contentModel else {
                        throw WebInspectorError.scriptUnavailable
                    }
                    let payload = try await content.captureSnapshot(maxDepth: depth)
                    self.sendResponse(id: request.id, result: payload.rawJSON)
                case "DOM.requestChildNodes":
                    let depth = (request.params["depth"] as? Int) ?? WebInspectorConstants.subtreeDepth
                    let identifier = request.params["nodeId"] as? Int ?? 0
                    guard let content = self.bridge?.contentModel else {
                        throw WebInspectorError.scriptUnavailable
                    }
                    let subtree = try await content.captureSubtree(identifier: identifier, maxDepth: depth)
                    self.sendResponse(id: request.id, result: subtree.rawJSON)
                case "DOM.highlightNode":
                    if let identifier = request.params["nodeId"] as? Int {
                        await self.bridge?.contentModel.highlightDOMNode(id: identifier)
                    }
                    self.sendResponse(id: request.id, result: [:])
                case "Overlay.hideHighlight", "DOM.hideHighlight":
                    self.bridge?.contentModel.clearWebInspectorHighlight()
                    self.sendResponse(id: request.id, result: [:])
                default:
                    self.sendError(id: request.id, message: "Unsupported method: \(request.method)")
                }
            } catch {
                self.sendError(id: request.id, message: error.localizedDescription)
            }
        }
    }

    private func dispatchToFrontend(_ message: Any) {
        guard let webView else { return }
        Task { @MainActor in
            do {
                let _ = try await webView.callAsyncJavaScript(
                    "return (() => { window.webInspectorKit?.dispatchMessageFromBackend?.(message); return null; })();",
                    arguments: ["message": message],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                coordinatorLogger.error("dispatch to frontend failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendResponse(id: Int, result: Any) {
        var message: [String: Any] = ["id": id]
        message["result"] = result
        dispatchToFrontend(message)
    }

    private func sendError(id: Int, message: String) {
        let payload: [String: Any] = [
            "id": id,
            "error": ["message": message]
        ]
        dispatchToFrontend(payload)
    }

    private func flushPendingWork() {
        if let preferredDepth = pendingPreferredDepth {
            applyPreferredDepthNow(preferredDepth)
            pendingPreferredDepth = nil
        }
        if let request = pendingDocumentRequest {
            requestDocumentNow(depth: request.depth, preserveState: request.preserveState)
            pendingDocumentRequest = nil
        }
        if !pendingBundles.isEmpty {
            pendingBundles.forEach { applyBundleNow($0) }
            pendingBundles.removeAll()
        }
        if let term = pendingSearchTerm {
            applySearchTermNow(term)
            pendingSearchTerm = nil
        }
    }

    private func applyBundleNow(_ payload: WebInspectorBridge.PendingBundle) {
        guard let webView else { return }
        Task { @MainActor in
            do {
                let _ = try await webView.callAsyncJavaScript(
                    "return (() => { window.webInspectorKit?.applyMutationBundle?.(bundle); return null; })();",
                    arguments: ["bundle": ["bundle": payload.rawJSON, "preserveState": payload.preserveState]],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                coordinatorLogger.error("send mutation bundle failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applySearchTermNow(_ term: String) {
        guard let webView else { return }
        Task { @MainActor in
            do {
                let _ = try await webView.callAsyncJavaScript(
                    "return (() => { window.webInspectorKit?.setSearchTerm?.(term); return null; })();",
                    arguments: ["term": term],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                coordinatorLogger.error("send search term failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyPreferredDepthNow(_ depth: Int) {
        guard let webView else { return }
        Task { @MainActor in
            do {
                let _ = try await webView.callAsyncJavaScript(
                    "return (() => { window.webInspectorKit?.setPreferredDepth?.(depth); return null; })();",
                    arguments: ["depth": depth],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                coordinatorLogger.error("send preferred depth failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func requestDocumentNow(depth: Int, preserveState: Bool) {
        guard let webView else { return }
        Task { @MainActor in
            do {
                let _ = try await webView.callAsyncJavaScript(
                    "return (() => { window.webInspectorKit?.requestDocument?.(options); return null; })();",
                    arguments: ["options": ["depth": depth, "preserveState": preserveState]],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                coordinatorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

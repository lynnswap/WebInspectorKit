//
//  WebInspectorContentModel.swift
//  WebInspectorKit
//
//  Created by Kazuki Nakashima on 2025/11/20.
//

import SwiftUI
import OSLog
import WebKit
import Observation

private let contentLogger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorContentModel")

@MainActor
@Observable
final class WebInspectorContentModel: NSObject {
    private enum HandlerName {
        static let snapshot = "webInspectorSnapshotUpdate"
        static let mutation = "webInspectorMutationUpdate"
    }

    weak var bridge: WebInspectorBridge?
    weak var pageWebView: WKWebView? {
        didSet {
            guard oldValue !== pageWebView else { return }
            detachMessageHandlers(from: oldValue)
            registerMessageHandlers(for: pageWebView)
        }
    }
    @ObservationIgnored private weak var registeredMessageWebView: WKWebView?

    private func registerMessageHandlers(for webView: WKWebView?) {
        guard let webView else {
            registeredMessageWebView = nil
            return
        }
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: .page, name: HandlerName.snapshot)
        controller.add(self, contentWorld: .page, name: HandlerName.mutation)
        registeredMessageWebView = webView
    }

    private func detachMessageHandlers(from webView: WKWebView?) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: HandlerName.snapshot, contentWorld: .page)
        controller.removeScriptMessageHandler(forName: HandlerName.mutation, contentWorld: .page)
        if registeredMessageWebView === webView {
            registeredMessageWebView = nil
        }
    }
}

extension WebInspectorContentModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case HandlerName.snapshot:
            handleSnapshotMessage(message)
        case HandlerName.mutation:
            handleMutationMessage(message)
        default:
            break
        }
    }

    private func handleSnapshotMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let rawJSON = payload["snapshot"] as? String else {
            return
        }
        let package = WebInspectorSnapshotPackage(rawJSON: rawJSON)
        bridge?.handleSnapshotFromPage(package)
    }

    private func handleMutationMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let rawJSON = payload["bundle"] as? String ?? payload["updates"] as? String else {
            return
        }
        let package = WebInspectorDOMUpdatePayload(rawJSON: rawJSON)
        bridge?.handleDomUpdateFromPage(package)
    }
}

// MARK: - Page WebView helpers

@MainActor
extension WebInspectorContentModel {
    func captureSnapshot(maxDepth: Int = WebInspectorConstants.defaultDepth) async throws -> WebInspectorSnapshotPackage {
        guard let pageWebView else {
            throw WebInspectorError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: pageWebView)
        let rawResult = try await pageWebView.callAsyncJavaScript(
            "return window.webInspectorKit.captureDOM(maxDepth)",
            arguments: ["maxDepth": maxDepth],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return WebInspectorSnapshotPackage(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func captureSubtree(identifier: Int, maxDepth: Int = WebInspectorConstants.subtreeDepth) async throws -> WebInspectorSubtreePayload {
        guard let pageWebView else {
            throw WebInspectorError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: pageWebView)
        let rawResult = try await pageWebView.callAsyncJavaScript(
            "return window.webInspectorKit.captureDOMSubtree(identifier, maxDepth)",
            arguments: ["identifier": identifier, "maxDepth": maxDepth],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        guard !data.isEmpty else {
            throw WebInspectorError.subtreeUnavailable
        }
        return WebInspectorSubtreePayload(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func beginSelectionMode() async throws -> WebInspectorSelectionResult {
        guard let pageWebView else {
            throw WebInspectorError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: pageWebView)
        let rawResult = try await pageWebView.callAsyncJavaScript(
            "return window.webInspectorKit.startElementSelection()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(WebInspectorSelectionResult.self, from: data)
    }

    func cancelSelectionMode() async {
        guard let pageWebView else { return }
        try? await injectScriptIfNeeded(on: pageWebView)
        _ = try? await pageWebView.callAsyncJavaScript(
            "return window.webInspectorKit.cancelElementSelection()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    func highlightDOMNode(id: Int) async {
        guard let pageWebView else { return }
        try? await injectScriptIfNeeded(on: pageWebView)
        _ = try? await pageWebView.callAsyncJavaScript(
            "(() => { window.webInspectorKit.highlightDOMNode(identifier); return null; })();",
            arguments: ["identifier": id],
            in: nil,
            contentWorld: .page
        )
    }

    func clearWebInspectorHighlight() {
        pageWebView?.evaluateJavaScript("window.webInspectorKit && window.webInspectorKit.clearHighlight();", completionHandler: nil)
    }

    func setAutoUpdate(enabled: Bool, maxDepth: Int) async {
        guard let pageWebView else { return }
        do {
            try await injectScriptIfNeeded(on: pageWebView)
            let debounce = max(50, Int(WebInspectorConstants.autoUpdateDebounce * 1000))
            _ = try await pageWebView.callAsyncJavaScript(
                "(() => { window.webInspectorKit.setAutoSnapshotEnabled(enabled, options); return null; })();",
                arguments: [
                    "enabled": enabled,
                    "options": [
                        "maxDepth": max(1, maxDepth),
                        "debounce": debounce
                    ]
                ],
                in: nil,
                contentWorld: .page
            )
        } catch {
            contentLogger.error("configure auto snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func injectScriptIfNeeded(on webView: WKWebView) async throws {
        let script = try WebInspectorScript.bootstrap()
        _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
    }

    private func serializePayload(_ payload: Any?) throws -> Data {
        guard let payload else {
            contentLogger.error("snapshot payload is nil")
            throw WebInspectorError.serializationFailed
        }

        let resolved = unwrapOptionalPayload(payload) ?? payload

        if let string = resolved as? String {
            return Data(string.utf8)
        }
        if let dictionary = resolved as? [String: Any] {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                contentLogger.error("snapshot payload dictionary is invalid for JSON serialization")
                throw WebInspectorError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = resolved as? [Any] {
            guard JSONSerialization.isValidJSONObject(array) else {
                contentLogger.error("snapshot payload array is invalid for JSON serialization")
                throw WebInspectorError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }
        contentLogger.error("unexpected snapshot payload type: \(String(describing: type(of: resolved)), privacy: .public)")
        throw WebInspectorError.serializationFailed
    }

    private func unwrapOptionalPayload(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let child = mirror.children.first else {
            return nil
        }
        return unwrapOptionalPayload(child.value)
    }
}

private enum WebInspectorScript {
    @MainActor private static var cachedScript: String?
    private static let resourceName = "InspectorAgent"
    private static let resourceExtension = "js"

    @MainActor static func bootstrap() throws -> String {
        if let cachedScript {
            return cachedScript
        }
        guard let url = WebInspectorAssets.locateResource(named: resourceName, withExtension: resourceExtension) else {
            contentLogger.error("missing web inspector script resource")
            throw WebInspectorError.scriptUnavailable
        }
        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            cachedScript = script
            return script
        } catch {
            contentLogger.error("failed to load web inspector script: \(error.localizedDescription, privacy: .public)")
            throw WebInspectorError.scriptUnavailable
        }
    }
}

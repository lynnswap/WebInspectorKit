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

private let contentLogger = Logger(subsystem: "WebInspectorKit", category: "WIContentModel")

@MainActor
@Observable
final class WIContentModel: NSObject {
    private enum HandlerName {
        static let snapshot = "webInspectorSnapshotUpdate"
        static let mutation = "webInspectorMutationUpdate"
    }

    weak var bridge: WIBridgeModel?
    weak var webView: WKWebView? {
        didSet {
            guard oldValue !== webView else { return }
            detachMessageHandlers(from: oldValue)
            registerMessageHandlers()
        }
    }

    private func registerMessageHandlers() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.add(self, contentWorld: .page, name: HandlerName.snapshot)
        controller.add(self, contentWorld: .page, name: HandlerName.mutation)
    }

    private func detachMessageHandlers(from webView: WKWebView?) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: HandlerName.snapshot, contentWorld: .page)
        controller.removeScriptMessageHandler(forName: HandlerName.mutation, contentWorld: .page)
        contentLogger.debug("detached content message handlers")
    }

    @MainActor deinit {
        detachMessageHandlers(from: webView)
    }
}

extension WIContentModel: WKScriptMessageHandler {
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
        let package = WISnapshotPackage(rawJSON: rawJSON)
        bridge?.handleSnapshotFromPage(package)
    }

    private func handleMutationMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let rawJSON = payload["bundle"] as? String ?? payload["updates"] as? String else {
            return
        }
        let package = WIDOMUpdatePayload(rawJSON: rawJSON)
        bridge?.handleDomUpdateFromPage(package)
    }
}

// MARK: - Page WebView helpers

@MainActor
extension WIContentModel {
    func captureSnapshot(maxDepth: Int = WIConstants.defaultDepth) async throws -> WISnapshotPackage {
        guard let webView else {
            throw WIError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: webView)
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorKit.captureDOM(maxDepth)",
            arguments: ["maxDepth": maxDepth],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return WISnapshotPackage(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func captureSubtree(identifier: Int, maxDepth: Int = WIConstants.subtreeDepth) async throws -> WISubtreePayload {
        guard let webView else {
            throw WIError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: webView)
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorKit.captureDOMSubtree(identifier, maxDepth)",
            arguments: ["identifier": identifier, "maxDepth": maxDepth],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        guard !data.isEmpty else {
            throw WIError.subtreeUnavailable
        }
        return WISubtreePayload(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func beginSelectionMode() async throws -> WISelectionResult {
        guard let webView else {
            throw WIError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: webView)
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorKit.startElementSelection()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(WISelectionResult.self, from: data)
    }

    func cancelSelectionMode() async {
        guard let webView else { return }
        try? await injectScriptIfNeeded(on: webView)
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorKit.cancelElementSelection()",
            contentWorld: .page
        )
    }

    func highlightDOMNode(id: Int) async {
        guard let webView else { return }
        try? await injectScriptIfNeeded(on: webView)
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorKit.highlightDOMNode(identifier)",
            arguments: ["identifier": id],
            contentWorld: .page
        )
    }

    func removeNode(identifier: Int) async {
        guard let webView else { return }
        do {
            try await injectScriptIfNeeded(on: webView)
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit.removeNode(identifier)",
                arguments: ["identifier": identifier],
                contentWorld: .page
            )
        } catch {
            contentLogger.error("remove node error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clearWebInspectorHighlight() {
        webView?.evaluateJavaScript("window.webInspectorKit && window.webInspectorKit.clearHighlight();", completionHandler: nil)
    }

    func selectionCopyText(for identifier: Int, kind: WISelectionCopyKind) async throws -> String {
        try await evaluateStringScript("""
        return window.webInspectorKit?.\(kind.jsFunction)(identifier) ?? \"\"
        """, identifier: identifier)
    }

    func setAutoUpdate(enabled: Bool, maxDepth: Int) async {
        guard let webView else { return }
        do {
            try await injectScriptIfNeeded(on: webView)
            let debounce = max(50, Int(WIConstants.autoUpdateDebounce * 1000))
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit.setAutoSnapshotEnabled(enabled, options)",
                arguments: [
                    "enabled": enabled,
                    "options": [
                        "maxDepth": max(1, maxDepth),
                        "debounce": debounce
                    ]
                ],
                contentWorld: .page
            )
        } catch {
            contentLogger.error("configure auto snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopInspection(maxDepth: Int) {
        clearWebInspectorHighlight()
        Task {
            await cancelSelectionMode()
            await setAutoUpdate(enabled: false, maxDepth: maxDepth)
        }
    }

    func setAttributeValue(identifier: Int, name: String, value: String) async {
        guard let webView else { return }
        do {
            try await injectScriptIfNeeded(on: webView)
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit.setAttributeForNode(identifier, name, value)",
                arguments: [
                    "identifier": identifier,
                    "name": name,
                    "value": value
                ],
                contentWorld: .page
            )
        } catch {
            contentLogger.error("set attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeAttribute(identifier: Int, name: String) async {
        guard let webView else { return }
        do {
            try await injectScriptIfNeeded(on: webView)
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorKit.removeAttributeForNode(identifier, name)",
                arguments: [
                    "identifier": identifier,
                    "name": name
                ],
                contentWorld: .page
            )
        } catch {
            contentLogger.error("remove attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evaluateStringScript(_ script: String, identifier: Int) async throws -> String {
        guard let webView else {
            throw WIError.scriptUnavailable
        }
        try await injectScriptIfNeeded(on: webView)
        let rawResult = try await webView.callAsyncJavaScript(
            script,
            arguments: ["identifier": identifier],
            in: nil,
            contentWorld: .page
        )
        return rawResult as? String ?? ""
    }

    private func injectScriptIfNeeded(on webView: WKWebView) async throws {
        let script = try WIScript.bootstrap()
        _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
    }

    private func serializePayload(_ payload: Any?) throws -> Data {
        guard let payload else {
            contentLogger.error("snapshot payload is nil")
            throw WIError.serializationFailed
        }

        let resolved = unwrapOptionalPayload(payload) ?? payload

        if let string = resolved as? String {
            return Data(string.utf8)
        }
        if let dictionary = resolved as? [String: Any] {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                contentLogger.error("snapshot payload dictionary is invalid for JSON serialization")
                throw WIError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = resolved as? [Any] {
            guard JSONSerialization.isValidJSONObject(array) else {
                contentLogger.error("snapshot payload array is invalid for JSON serialization")
                throw WIError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }
        contentLogger.error("unexpected snapshot payload type: \(String(describing: type(of: resolved)), privacy: .public)")
        throw WIError.serializationFailed
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

private enum WIScript {
    @MainActor private static var cachedScript: String?
    private static let resourceName = "InspectorAgent"
    private static let resourceExtension = "js"

    @MainActor static func bootstrap() throws -> String {
        if let cachedScript {
            return cachedScript
        }
        guard let url = WIAssets.locateResource(
            named: resourceName,
            withExtension: resourceExtension,
            subdirectory: "WebInspector/Support"
        ) else {
            contentLogger.error("missing web inspector script resource")
            throw WIError.scriptUnavailable
        }
        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            cachedScript = script
            return script
        } catch {
            contentLogger.error("failed to load web inspector script: \(error.localizedDescription, privacy: .public)")
            throw WIError.scriptUnavailable
        }
    }
}

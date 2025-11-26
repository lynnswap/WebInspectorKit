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
private let inspectorPresenceProbeScript: String = """
(function() { })();
"""
@MainActor
@Observable
final class WIContentModel: NSObject {
    private enum HandlerName :String, CaseIterable{
        case snapshot = "webInspectorSnapshotUpdate"
        case mutation = "webInspectorMutationUpdate"
    }

    weak var bridge: WIBridgeModel?
    private(set) weak var webView: WKWebView?

    private var configuration: WebInspectorModel.Configuration {
        bridge?.configuration ?? .init()
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        guard self.webView !== newWebView else { return }
        guard let newWebView else {
            detachPageWebView()
            return
        }
        if let previousWebView = self.webView {
            stopAutoUpdate(for:previousWebView)
            detachMessageHandlers(from: previousWebView)
        }
        self.webView = newWebView
        registerMessageHandlers()
        Task {
            await self.setAutoUpdate(for: newWebView, maxDepth: self.configuration.snapshotDepth)
        }
    }

    func detachPageWebView() {
        guard let currentWebView = webView else { return }
        stopAutoUpdate(for:currentWebView)
        detachMessageHandlers(from: currentWebView)
        webView = nil
    }

    private func registerMessageHandlers() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue,contentWorld: .page)
            controller.add(self, contentWorld: .page, name: $0.rawValue)
        }
        installInspectorAgentScriptIfNeeded(on: webView)
    }

    private func detachMessageHandlers(from webView: WKWebView?) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
        }
        contentLogger.debug("detached content message handlers")
    }

    private func installInspectorAgentScriptIfNeeded(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if controller.userScripts.contains(where: { $0.source == inspectorPresenceProbeScript }) {
            return
        }
        
        let scriptSource: String
        do {
            scriptSource = try WIScript.bootstrap()
        } catch {
            contentLogger.error("failed to prepare inspector script: \(error.localizedDescription, privacy: .public)")
            return
        }
        
        let userScript = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        let checkScript = WKUserScript(
            source: inspectorPresenceProbeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(userScript)
        controller.addUserScript(checkScript)
        Task{
            _ = try? await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: .page)
        }
        contentLogger.debug("installed inspector agent user script")
        
    }

    @MainActor deinit {
        detachPageWebView()
    }
}

extension WIContentModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handlerName = HandlerName(rawValue: message.name) else { return }
        switch handlerName {
        case .snapshot:
            handleSnapshotMessage(message)
        case .mutation:
            handleMutationMessage(message)
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
    func captureSnapshot(maxDepth: Int? = nil) async throws -> WISnapshotPackage {
        guard let webView else {
            throw WIError.scriptUnavailable
        }
        let depth = maxDepth ?? configuration.snapshotDepth
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorKit.captureDOM(maxDepth)",
            arguments: ["maxDepth": depth],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return WISnapshotPackage(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func captureSubtree(identifier: Int, maxDepth: Int? = nil) async throws -> WISubtreePayload {
        guard let webView else {
            throw WIError.scriptUnavailable
        }
        let depth = maxDepth ?? configuration.subtreeDepth
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorKit.captureDOMSubtree(identifier, maxDepth)",
            arguments: ["identifier": identifier, "maxDepth": depth],
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
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorKit.startElementSelection()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(WISelectionResult.self, from: data)
    }

    func cancelSelectionMode(using targetWebView: WKWebView? = nil) async {
        guard let webView = targetWebView ?? self.webView else { return }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorKit.cancelElementSelection()",
            contentWorld: .page
        )
    }

    func highlightDOMNode(id: Int) async {
        guard let webView else { return }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorKit.highlightDOMNode(identifier)",
            arguments: ["identifier": id],
            contentWorld: .page
        )
    }

    func removeNode(identifier: Int) async {
        guard let webView else { return }
        do {
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
    private func stopAutoUpdate(for webView: WKWebView){
        webView.evaluateJavaScript("(() => { window.webInspectorKit.detach(); })();  ",in: nil, in: .page)
    }
    private func setAutoUpdate(for webView: WKWebView, maxDepth: Int) async {
        do {
            let debounce = max(50, Int(configuration.autoUpdateDebounce * 1000))
            let options: [String: Any] = [
                "maxDepth": max(1, maxDepth),
                "debounce": debounce
            ]
            try await webView.callAsyncVoidJavaScript(
                """
                window.webInspectorKit.setAutoSnapshotOptions(options);
                window.webInspectorKit.setAutoSnapshotEnabled();
                """,
                arguments: ["options": options],
                contentWorld: .page
            )
        } catch {
            contentLogger.error("configure/enable auto snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setAttributeValue(identifier: Int, name: String, value: String) async {
        guard let webView else { return }
        do {
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
        let rawResult = try await webView.callAsyncJavaScript(
            script,
            arguments: ["identifier": identifier],
            in: nil,
            contentWorld: .page
        )
        return rawResult as? String ?? ""
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

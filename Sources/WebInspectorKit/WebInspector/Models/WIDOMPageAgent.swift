import SwiftUI
import OSLog
import WebKit
import Observation

private let domLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMPageAgent")
private let inspectorPresenceProbeScript: String = """
(function() { })();
"""

@MainActor
@Observable
final class WIDOMPageAgent: NSObject, WIPageAgent {
    struct SnapshotPackage {
        let rawJSON: String
    }

    struct SubtreePayload: Equatable {
        let rawJSON: String
    }

    struct DOMUpdatePayload: Equatable {
        let rawJSON: String
    }

    struct SelectionResult: Decodable {
        let cancelled: Bool
        let requiredDepth: Int
    }

    private enum HandlerName: String, CaseIterable {
        case snapshot = "webInspectorSnapshotUpdate"
        case mutation = "webInspectorMutationUpdate"
    }

    weak var inspector: WIDOMStore?
    var selection = WIDOMSelection()
    weak var webView: WKWebView?
    private var configuration: WebInspectorConfiguration

    init(configuration: WebInspectorConfiguration) {
        self.configuration = configuration
    }

    @MainActor deinit {
        detachPageWebView()
    }

    func updateConfiguration(_ configuration: WebInspectorConfiguration) {
        self.configuration = configuration
    }

    func cancelSelectionMode(using targetWebView: WKWebView? = nil) async {
        guard let webView = targetWebView ?? self.webView else { return }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorKit.cancelElementSelection()",
            contentWorld: .page
        )
    }

    func clearWebInspectorHighlight() {
        webView?.evaluateJavaScript("window.webInspectorKit && window.webInspectorKit.clearHighlight();", completionHandler: nil)
    }
}

// MARK: - WKScriptMessageHandler

extension WIDOMPageAgent: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else {
            return
        }
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
              let rawJSON = payload["snapshot"] as? String,
              let inspector else {
            return
        }
        let package = SnapshotPackage(rawJSON: rawJSON)
        inspector.enqueueMutationBundle(package.rawJSON, preserveState: true)
    }

    private func handleMutationMessage(_ message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let rawJSON = payload["bundle"] as? String ?? payload["updates"] as? String,
              let inspector else {
            return
        }
        let package = DOMUpdatePayload(rawJSON: rawJSON)
        inspector.enqueueMutationBundle(package.rawJSON, preserveState: true)
    }
}

// MARK: - Page WebView helpers

@MainActor
extension WIDOMPageAgent {
    func captureSnapshot(maxDepth: Int? = nil) async throws -> SnapshotPackage {
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
        return SnapshotPackage(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func captureSubtree(identifier: Int, maxDepth: Int? = nil) async throws -> SubtreePayload {
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
        return SubtreePayload(rawJSON: String(decoding: data, as: UTF8.self))
    }

    func beginSelectionMode() async throws -> SelectionResult {
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
        return try JSONDecoder().decode(SelectionResult.self, from: data)
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
            domLogger.error("remove node error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateAttributeValue(identifier: Int, name: String, value: String) async {
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
            domLogger.error("set attribute failed: \(error.localizedDescription, privacy: .public)")
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
            domLogger.error("remove attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectionCopyText(for identifier: Int, kind: WISelectionCopyKind) async throws -> String {
        try await evaluateStringScript("""
        return window.webInspectorKit?.\(kind.jsFunction)(identifier) ?? \"\"
        """, identifier: identifier)
    }
}

// MARK: - WIPageAgent

extension WIDOMPageAgent {
    func willDetachPageWebView(_ webView: WKWebView) {
        stopAutoUpdate(for: webView)
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        registerMessageHandlers()
        Task {
            await self.setAutoUpdate(for: webView, maxDepth: self.configuration.snapshotDepth)
        }
    }

    func didClearPageWebView() {
        selection.clear()
    }
}

// MARK: - Private helpers

private extension WIDOMPageAgent {
    func registerMessageHandlers() {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
            controller.add(self, contentWorld: .page, name: $0.rawValue)
        }
        installInspectorAgentScriptIfNeeded(on: webView)
    }

    func detachMessageHandlers(from webView: WKWebView?) {
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
        }
        domLogger.debug("detached DOM message handlers")
    }

    func installInspectorAgentScriptIfNeeded(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if controller.userScripts.contains(where: { $0.source == inspectorPresenceProbeScript }) {
            return
        }

        let scriptSource: String
        do {
            scriptSource = try WIScript.bootstrapAgent()
        } catch {
            domLogger.error("failed to prepare inspector script: \(error.localizedDescription, privacy: .public)")
            return
        }

        let userScript = WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let checkScript = WKUserScript(
            source: inspectorPresenceProbeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(userScript)
        controller.addUserScript(checkScript)
        Task {
            _ = try? await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: .page)
        }
        domLogger.debug("installed inspector agent user script")
    }

    func stopAutoUpdate(for webView: WKWebView) {
        webView.evaluateJavaScript("(() => { window.webInspectorKit.detach(); })();  ", in: nil, in: .page)
    }

    func setAutoUpdate(for webView: WKWebView, maxDepth: Int) async {
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
            domLogger.error("configure/enable auto snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func evaluateStringScript(_ script: String, identifier: Int) async throws -> String {
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

    func serializePayload(_ payload: Any?) throws -> Data {
        guard let payload else {
            domLogger.error("snapshot payload is nil")
            throw WIError.serializationFailed
        }

        let resolved = unwrapOptionalPayload(payload) ?? payload

        if let string = resolved as? String {
            return Data(string.utf8)
        }
        if let dictionary = resolved as? [String: Any] {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                domLogger.error("snapshot payload dictionary is invalid for JSON serialization")
                throw WIError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = resolved as? [Any] {
            guard JSONSerialization.isValidJSONObject(array) else {
                domLogger.error("snapshot payload array is invalid for JSON serialization")
                throw WIError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }
        domLogger.error("unexpected snapshot payload type: \(String(describing: type(of: resolved)), privacy: .public)")
        throw WIError.serializationFailed
    }

    func unwrapOptionalPayload(_ value: Any) -> Any? {
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

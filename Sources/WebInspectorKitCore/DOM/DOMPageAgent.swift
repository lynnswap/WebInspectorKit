import Foundation
import OSLog
import WebKit

private let domLogger = Logger(subsystem: "WebInspectorKit", category: "DOMPageAgent")
private let domAgentPresenceProbeScript: String = """
(function() { /* webInspectorDOM */ })();
"""

@MainActor
public final class DOMPageAgent: NSObject, PageAgent {
    public struct SelectionModeResult: Decodable, Sendable {
        public let cancelled: Bool
        public let requiredDepth: Int
    }

    private enum HandlerName: String, CaseIterable {
        case snapshot = "webInspectorDOMSnapshot"
        case mutation = "webInspectorDOMMutations"
    }

    public weak var sink: (any DOMBundleSink)?
    weak var webView: WKWebView?
    private var configuration: DOMConfiguration

    public init(configuration: DOMConfiguration) {
        self.configuration = configuration
    }

    @MainActor deinit {
        detachPageWebView()
    }

    public func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
    }
}

// MARK: - WKScriptMessageHandler

extension DOMPageAgent: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else {
            return
        }
        guard HandlerName(rawValue: message.name) != nil else {
            return
        }
        guard let payload = message.body as? [String: Any],
              let rawJSON = payload["bundle"] as? String,
              !rawJSON.isEmpty else {
            return
        }
        sink?.domDidEmit(bundle: DOMBundle(rawJSON: rawJSON))
    }
}

// MARK: - Selection / Highlight

public extension DOMPageAgent {
    func beginSelectionMode() async throws -> SelectionModeResult {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.startSelection()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(SelectionModeResult.self, from: data)
    }

    func cancelSelectionMode() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.cancelSelection()",
            contentWorld: .page
        )
    }

    func highlight(nodeId: Int) async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.highlightNode(identifier)",
            arguments: ["identifier": nodeId],
            contentWorld: .page
        )
    }

    func hideHighlight() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM && window.webInspectorDOM.clearHighlight();",
            contentWorld: .page
        )
    }
}

// MARK: - DOM Snapshot

public extension DOMPageAgent {
    func captureSnapshot(maxDepth: Int) async throws -> String {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.captureSnapshot(maxDepth)",
            arguments: ["maxDepth": max(1, maxDepth)],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        return String(decoding: data, as: UTF8.self)
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.captureSubtree(identifier, maxDepth)",
            arguments: ["identifier": nodeId, "maxDepth": max(1, maxDepth)],
            in: nil,
            contentWorld: .page
        )
        let data = try serializePayload(rawResult)
        guard !data.isEmpty else {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - DOM Mutations

public extension DOMPageAgent {
    func removeNode(nodeId: Int) async {
        guard let webView else {
            return
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.removeNode(identifier)",
                arguments: ["identifier": nodeId],
                contentWorld: .page
            )
        } catch {
            domLogger.error("remove node failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        guard let webView else {
            return
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.setAttributeForNode(identifier, name, value)",
                arguments: [
                    "identifier": nodeId,
                    "name": name,
                    "value": value,
                ],
                contentWorld: .page
            )
        } catch {
            domLogger.error("set attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeAttribute(nodeId: Int, name: String) async {
        guard let webView else {
            return
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.removeAttributeForNode(identifier, name)",
                arguments: [
                    "identifier": nodeId,
                    "name": name,
                ],
                contentWorld: .page
            )
        } catch {
            domLogger.error("remove attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await evaluateStringScript(
            """
            return window.webInspectorDOM?.\(kind.jsFunction)(identifier) ?? ""
            """,
            nodeId: nodeId
        )
    }
}

// MARK: - Auto Snapshot

public extension DOMPageAgent {
    func setAutoSnapshot(enabled: Bool) async {
        guard let webView else {
            return
        }
        let debounceMs = max(50, Int(configuration.autoUpdateDebounce * 1000))
        let options: [String: Any] = [
            "maxDepth": max(1, configuration.snapshotDepth),
            "debounce": debounceMs,
            "enabled": enabled,
        ]
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.configureAutoSnapshot(options)",
                arguments: ["options": options],
                contentWorld: .page
            )
        } catch {
            domLogger.error("configure auto snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - PageAgent

extension DOMPageAgent {
    func willDetachPageWebView(_ webView: WKWebView) {
        // Stop observers if the script is installed. This is best-effort.
        Task {
            try? await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM && window.webInspectorDOM.detach && window.webInspectorDOM.detach();",
                contentWorld: .page
            )
        }
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        registerMessageHandlers(on: webView)
        installDOMAgentScriptIfNeeded(on: webView)
    }

    func didClearPageWebView() {}
}

// MARK: - Private helpers

private extension DOMPageAgent {
    func registerMessageHandlers(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
            controller.add(self, contentWorld: .page, name: $0.rawValue)
        }
    }

    func detachMessageHandlers(from webView: WKWebView) {
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: .page)
        }
        domLogger.debug("detached DOM message handlers")
    }

    func installDOMAgentScriptIfNeeded(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if controller.userScripts.contains(where: { $0.source == domAgentPresenceProbeScript }) {
            return
        }

        let scriptSource: String
        do {
            scriptSource = try WebInspectorScripts.domAgent()
        } catch {
            domLogger.error("failed to prepare DOM agent script: \(error.localizedDescription, privacy: .public)")
            return
        }

        controller.addUserScript(
            WKUserScript(
                source: scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: domAgentPresenceProbeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        // Install into already-loaded documents too.
        Task {
            _ = try? await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: .page)
        }
        domLogger.debug("installed DOM agent user script")
    }

    func evaluateStringScript(_ script: String, nodeId: Int) async throws -> String {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            script,
            arguments: ["identifier": nodeId],
            in: nil,
            contentWorld: .page
        )
        return rawResult as? String ?? ""
    }

    func serializePayload(_ payload: Any?) throws -> Data {
        guard let payload else {
            domLogger.error("DOM payload is nil")
            throw WebInspectorCoreError.serializationFailed
        }

        let resolved = unwrapOptionalPayload(payload) ?? payload

        if let string = resolved as? String {
            return Data(string.utf8)
        }
        if let dictionary = resolved as? [String: Any] {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                domLogger.error("DOM payload dictionary is invalid for JSON serialization")
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = resolved as? [Any] {
            guard JSONSerialization.isValidJSONObject(array) else {
                domLogger.error("DOM payload array is invalid for JSON serialization")
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }

        domLogger.error("unexpected DOM payload type: \(String(describing: type(of: resolved)), privacy: .public)")
        throw WebInspectorCoreError.serializationFailed
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

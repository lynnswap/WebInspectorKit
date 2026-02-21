import Foundation
import OSLog
import ObjectiveC.runtime
import WebKit

private let domLogger = Logger(subsystem: "WebInspectorKit", category: "DOMPageAgent")
private let domAgentPresenceProbeScript: String = """
(function() { /* webInspectorDOM */ })();
"""
private let autoSnapshotConfigureRetryCount = 20
private let autoSnapshotConfigureRetryDelayNanoseconds: UInt64 = 50_000_000
private let unavailablePrivateAPISentinel = "__wi_private_unavailable__"
@MainActor private var domBridgeScriptInstalledKey: UInt8 = 0

@MainActor
private extension WKUserContentController {
    var wi_domBridgeScriptInstalled: Bool {
        get {
            (objc_getAssociatedObject(self, &domBridgeScriptInstalledKey) as? NSNumber)?.boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &domBridgeScriptInstalledKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

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

    private enum HandleCommand {
        case highlight
        case removeNode
        case setAttribute(name: String, value: String)
        case removeAttribute(name: String)

        var functionName: String {
            switch self {
            case .highlight:
                return "highlightNodeHandle"
            case .removeNode:
                return "removeNodeHandle"
            case .setAttribute:
                return "setAttributeForHandle"
            case .removeAttribute:
                return "removeAttributeForHandle"
            }
        }
    }

    public weak var sink: (any DOMBundleSink)?
    weak var webView: WKWebView?
    private var configuration: DOMConfiguration

    private let runtime: WISPIRuntime
    private let bridgeWorld: WKContentWorld
    private let handleCache = WIJSHandleCache(capacity: 128)
    private var bridgeMode: WIBridgeMode
    private var bridgeModeLocked = false

    package var currentBridgeMode: WIBridgeMode {
        bridgeMode
    }

    public init(configuration: DOMConfiguration) {
        self.configuration = configuration
        runtime = .shared
        bridgeMode = runtime.startupMode()
        bridgeWorld = WISPIContentWorldProvider.bridgeWorld(runtime: runtime)
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
        guard let payload = message.body as? NSDictionary,
              let bundle = payload["bundle"]
        else {
            return
        }

        if let rawJSON = bundle as? String, !rawJSON.isEmpty {
            sink?.domDidEmit(bundle: DOMBundle(rawJSON: rawJSON))
            return
        }

        sink?.domDidEmit(bundle: DOMBundle(objectEnvelope: bundle))
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
            contentWorld: bridgeWorld
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
            contentWorld: bridgeWorld
        )
    }

    func highlight(nodeId: Int) async {
        guard let webView else {
            return
        }
        if await runHandleCommand(.highlight, nodeId: nodeId, on: webView) {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.highlightNode(identifier)",
            arguments: ["identifier": nodeId],
            contentWorld: bridgeWorld
        )
    }

    func hideHighlight() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM && window.webInspectorDOM.clearHighlight();",
            contentWorld: bridgeWorld
        )
    }
}

// MARK: - DOM Snapshot

public extension DOMPageAgent {
    func captureSnapshot(maxDepth: Int) async throws -> String {
        let payload = try await snapshotPayload(maxDepth: maxDepth, preferEnvelope: false)
        return try jsonString(from: payload)
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        let payload = try await subtreePayload(nodeId: nodeId, maxDepth: maxDepth, preferEnvelope: false)
        let json = try jsonString(from: payload)
        guard !json.isEmpty else {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        return json
    }

    func matchedStyles(nodeId: Int, maxRules: Int = 0) async throws -> DOMMatchedStylesPayload {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.matchedStylesForNode(identifier, options)",
            arguments: [
                "identifier": nodeId,
                "options": ["maxRules": maxRules],
            ],
            in: nil,
            contentWorld: bridgeWorld
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(DOMMatchedStylesPayload.self, from: data)
    }

    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        try await snapshotPayload(maxDepth: maxDepth, preferEnvelope: bridgeMode != .legacyJSON)
    }

    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        try await subtreePayload(nodeId: nodeId, maxDepth: maxDepth, preferEnvelope: bridgeMode != .legacyJSON)
    }
}

// MARK: - DOM Mutations

public extension DOMPageAgent {
    func removeNode(nodeId: Int) async {
        guard let webView else {
            return
        }
        do {
            if await runHandleCommand(.removeNode, nodeId: nodeId, on: webView) {
                handleCache.removeHandle(for: nodeId)
                return
            }
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.removeNode(identifier)",
                arguments: ["identifier": nodeId],
                contentWorld: bridgeWorld
            )
            handleCache.removeHandle(for: nodeId)
        } catch {
            domLogger.error("remove node failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        guard let webView else {
            return nil
        }
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.removeNodeWithUndo(identifier)",
                arguments: ["identifier": nodeId],
                in: nil,
                contentWorld: bridgeWorld
            )
            if let number = rawValue as? NSNumber {
                let token = number.intValue
                if token > 0 {
                    handleCache.removeHandle(for: nodeId)
                    return token
                }
                return nil
            }
            if let token = rawValue as? Int, token > 0 {
                handleCache.removeHandle(for: nodeId)
                return token
            }
            return nil
        } catch {
            domLogger.error("remove node with undo failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        guard let webView else {
            return false
        }
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.undoRemoveNode(token)",
                arguments: ["token": undoToken],
                in: nil,
                contentWorld: bridgeWorld
            )
            if let boolValue = rawValue as? Bool {
                return boolValue
            }
            if let number = rawValue as? NSNumber {
                return number.boolValue
            }
            return false
        } catch {
            domLogger.error("undo remove node failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int? = nil) async -> Bool {
        guard let webView else {
            return false
        }
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.redoRemoveNode(token)",
                arguments: ["token": undoToken],
                in: nil,
                contentWorld: bridgeWorld
            )
            let succeeded = (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
            if succeeded, let nodeId {
                handleCache.removeHandle(for: nodeId)
            }
            return succeeded
        } catch {
            domLogger.error("redo remove node failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        guard let webView else {
            return
        }
        do {
            if await runHandleCommand(.setAttribute(name: name, value: value), nodeId: nodeId, on: webView) {
                return
            }
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.setAttributeForNode(identifier, name, value)",
                arguments: [
                    "identifier": nodeId,
                    "name": name,
                    "value": value,
                ],
                contentWorld: bridgeWorld
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
            if await runHandleCommand(.removeAttribute(name: name), nodeId: nodeId, on: webView) {
                return
            }
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM.removeAttributeForNode(identifier, name)",
                arguments: [
                    "identifier": nodeId,
                    "name": name,
                ],
                contentWorld: bridgeWorld
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
        let options: NSDictionary = [
            "maxDepth": NSNumber(value: max(1, configuration.snapshotDepth)),
            "debounce": NSNumber(value: debounceMs),
            "enabled": NSNumber(value: enabled),
        ]
        do {
            let didConfigure = try await configureAutoSnapshotWhenReady(on: webView, options: options)
            if !didConfigure {
                domLogger.error("configure auto snapshot skipped: DOM agent is not ready")
            }
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
                contentWorld: bridgeWorld
            )
        }
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        resolveBridgeModeIfNeeded(with: webView)
        registerMessageHandlers(on: webView)
        installDOMAgentScriptIfNeeded(on: webView)
    }

    func didClearPageWebView() {
        handleCache.clear()
    }
}

// MARK: - Private helpers

private extension DOMPageAgent {
    func resolveBridgeModeIfNeeded(with webView: WKWebView) {
        guard !bridgeModeLocked else {
            return
        }
        bridgeMode = runtime.modeForAttachment(webView: webView)
        bridgeModeLocked = true
        domLogger.notice("bridge_mode=\(self.bridgeMode.rawValue, privacy: .public)")
    }

    func lockToLegacyMode(_ reason: String) {
        guard bridgeMode != .legacyJSON else {
            return
        }
        bridgeMode = .legacyJSON
        bridgeModeLocked = true
        handleCache.clear()
        domLogger.error("bridge_mode=legacyJSON \(reason, privacy: .public)")
    }

    func configureAutoSnapshotWhenReady(
        on webView: WKWebView,
        options: NSDictionary
    ) async throws -> Bool {
        for attempt in 0..<autoSnapshotConfigureRetryCount {
            let rawResult = try await webView.callAsyncJavaScript(
                """
                if (!window.webInspectorDOM || typeof window.webInspectorDOM.configureAutoSnapshot !== "function") {
                    return false;
                }
                window.webInspectorDOM.configureAutoSnapshot(options);
                return true;
                """,
                arguments: ["options": options],
                in: nil,
                contentWorld: bridgeWorld
            )
            let didConfigure = (rawResult as? Bool) ?? (rawResult as? NSNumber)?.boolValue ?? false
            if didConfigure {
                return true
            }
            if attempt < autoSnapshotConfigureRetryCount - 1 {
                try? await Task.sleep(nanoseconds: autoSnapshotConfigureRetryDelayNanoseconds)
            }
        }
        return false
    }

    func registerMessageHandlers(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: bridgeWorld)
            controller.add(self, contentWorld: bridgeWorld, name: $0.rawValue)
        }
    }

    func detachMessageHandlers(from webView: WKWebView) {
        let controller = webView.configuration.userContentController
        HandlerName.allCases.forEach {
            controller.removeScriptMessageHandler(forName: $0.rawValue, contentWorld: bridgeWorld)
        }
        domLogger.debug("detached DOM message handlers")
    }

    func installDOMAgentScriptIfNeeded(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if controller.wi_domBridgeScriptInstalled {
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
                forMainFrameOnly: true,
                in: bridgeWorld
            )
        )
        controller.addUserScript(
            WKUserScript(
                source: domAgentPresenceProbeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: bridgeWorld
            )
        )
        controller.wi_domBridgeScriptInstalled = true

        // Install into already-loaded documents too.
        Task {
            _ = try? await webView.evaluateJavaScript(scriptSource, in: nil, contentWorld: bridgeWorld)
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
            contentWorld: bridgeWorld
        )
        return rawResult as? String ?? ""
    }

    func snapshotPayload(maxDepth: Int, preferEnvelope: Bool) async throws -> Any {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            preferEnvelope
                ? """
                if (window.webInspectorDOM && typeof window.webInspectorDOM.captureSnapshotEnvelope === "function") {
                    return window.webInspectorDOM.captureSnapshotEnvelope(maxDepth);
                }
                return window.webInspectorDOM.captureSnapshot(maxDepth);
                """
                : "return window.webInspectorDOM.captureSnapshot(maxDepth)",
            arguments: ["maxDepth": max(1, maxDepth)],
            in: nil,
            contentWorld: bridgeWorld
        )
        return unwrapOptionalPayload(rawResult) as Any
    }

    func subtreePayload(nodeId: Int, maxDepth: Int, preferEnvelope: Bool) async throws -> Any {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScript(
            preferEnvelope
                ? """
                if (window.webInspectorDOM && typeof window.webInspectorDOM.captureSubtreeEnvelope === "function") {
                    return window.webInspectorDOM.captureSubtreeEnvelope(identifier, maxDepth);
                }
                return window.webInspectorDOM.captureSubtree(identifier, maxDepth);
                """
                : "return window.webInspectorDOM.captureSubtree(identifier, maxDepth)",
            arguments: [
                "identifier": nodeId,
                "maxDepth": max(1, maxDepth),
            ],
            in: nil,
            contentWorld: bridgeWorld
        )
        let payload = unwrapOptionalPayload(rawResult) as Any
        if let string = payload as? String, string.isEmpty {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        return payload
    }

    func jsonString(from payload: Any?) throws -> String {
        let resolved = unwrapOptionalPayload(payload) as Any

        if let string = resolved as? String {
            return string
        }

        if let dictionary = resolved as? NSDictionary {
            if let fallback = dictionary["fallback"], JSONSerialization.isValidJSONObject(fallback) {
                let data = try JSONSerialization.data(withJSONObject: fallback)
                return String(decoding: data, as: UTF8.self)
            }
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                throw WebInspectorCoreError.serializationFailed
            }
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            return String(decoding: data, as: UTF8.self)
        }

        if let array = resolved as? NSArray {
            guard JSONSerialization.isValidJSONObject(array) else {
                throw WebInspectorCoreError.serializationFailed
            }
            let data = try JSONSerialization.data(withJSONObject: array)
            return String(decoding: data, as: UTF8.self)
        }

        throw WebInspectorCoreError.serializationFailed
    }

    func serializePayload(_ payload: Any?) throws -> Data {
        let resolved = unwrapOptionalPayload(payload) as Any

        if let string = resolved as? String {
            return Data(string.utf8)
        }
        if let dictionary = resolved as? NSDictionary {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                domLogger.error("DOM payload dictionary is invalid for JSON serialization")
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = resolved as? NSArray {
            guard JSONSerialization.isValidJSONObject(array) else {
                domLogger.error("DOM payload array is invalid for JSON serialization")
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }

        domLogger.error("unexpected DOM payload type: \(String(describing: type(of: resolved)), privacy: .public)")
        throw WebInspectorCoreError.serializationFailed
    }

    func unwrapOptionalPayload(_ value: Any?) -> Any {
        guard let value else {
            return NSNull()
        }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let child = mirror.children.first else {
            return NSNull()
        }
        return unwrapOptionalPayload(child.value)
    }

    private func runHandleCommand(_ command: HandleCommand, nodeId: Int, on webView: WKWebView) async -> Bool {
        guard bridgeMode != .legacyJSON else {
            return false
        }
        guard let handle = await resolveHandle(for: nodeId, on: webView) else {
            return false
        }

        do {
            let invocation = makeHandleInvocation(command: command, handle: handle)
            let rawResult = try await webView.callAsyncJavaScript(
                invocation.script,
                arguments: invocation.arguments,
                in: nil,
                contentWorld: bridgeWorld
            )

            if let sentinel = rawResult as? String, sentinel == unavailablePrivateAPISentinel {
                lockToLegacyMode("selector_missing=\(command.functionName)")
                return false
            }

            let succeeded = (rawResult as? Bool) ?? (rawResult as? NSNumber)?.boolValue ?? false
            if !succeeded {
                if case .removeNode = command {
                    handleCache.removeHandle(for: nodeId)
                }
                return false
            }
            if case .removeNode = command {
                handleCache.removeHandle(for: nodeId)
            }
            return true
        } catch {
            lockToLegacyMode("runtime_probe_failed=\(command.functionName)")
            domLogger.error("handle command failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func resolveHandle(for nodeId: Int, on webView: WKWebView) async -> AnyObject? {
        if let cached = handleCache.handle(for: nodeId) {
            return cached
        }

        do {
            let rawResult = try await webView.callAsyncJavaScript(
                """
                if (!window.webInspectorDOM || typeof window.webInspectorDOM.createNodeHandle !== "function") {
                    return unavailable;
                }
                return window.webInspectorDOM.createNodeHandle(identifier);
                """,
                arguments: [
                    "identifier": nodeId,
                    "unavailable": unavailablePrivateAPISentinel,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )

            if let sentinel = rawResult as? String, sentinel == unavailablePrivateAPISentinel {
                lockToLegacyMode("selector_missing=createNodeHandle")
                return nil
            }

            let resolved = unwrapOptionalPayload(rawResult)
            guard !(resolved is NSNull) else {
                return nil
            }
            let handle = resolved as AnyObject

            handleCache.store(handle: handle, for: nodeId)
            return handle
        } catch {
            lockToLegacyMode("runtime_probe_failed=createNodeHandle")
            domLogger.error("resolve handle failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makeHandleInvocation(command: HandleCommand, handle: AnyObject) -> (script: String, arguments: [String: Any]) {
        var arguments: [String: Any] = [
            "handle": handle,
            "unavailable": unavailablePrivateAPISentinel,
        ]

        let script: String
        switch command {
        case .highlight:
            script = """
            if (!window.webInspectorDOM || typeof window.webInspectorDOM.highlightNodeHandle !== "function") {
                return unavailable;
            }
            return window.webInspectorDOM.highlightNodeHandle(handle);
            """

        case .removeNode:
            script = """
            if (!window.webInspectorDOM || typeof window.webInspectorDOM.removeNodeHandle !== "function") {
                return unavailable;
            }
            return window.webInspectorDOM.removeNodeHandle(handle);
            """

        case let .setAttribute(name, value):
            arguments["name"] = name
            arguments["value"] = value
            script = """
            if (!window.webInspectorDOM || typeof window.webInspectorDOM.setAttributeForHandle !== "function") {
                return unavailable;
            }
            return window.webInspectorDOM.setAttributeForHandle(handle, name, value);
            """

        case let .removeAttribute(name):
            arguments["name"] = name
            script = """
            if (!window.webInspectorDOM || typeof window.webInspectorDOM.removeAttributeForHandle !== "function") {
                return unavailable;
            }
            return window.webInspectorDOM.removeAttributeForHandle(handle, name);
            """
        }

        return (script: script, arguments: arguments)
    }
}

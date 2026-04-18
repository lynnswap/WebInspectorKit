import Foundation
import OSLog
import WebKit
import WebInspectorScripts
import WebInspectorBridge

private let domLogger = Logger(subsystem: "WebInspectorKit", category: "DOMPageBridge")
private let domAgentBootstrapWindowKey = "__wiDOMAgentBootstrap"
private let domAgentBootstrapScriptMarker = "__wiDOMAgentBootstrapUserScript"
package typealias DOMBridgeScriptInstaller = @MainActor (WKWebView, String, WKContentWorld) async throws -> Void

private struct DOMBootstrapConfiguration {
    let contextID: DOMContextID
    let autoSnapshotEnabled: Bool
    let autoSnapshotMaxDepth: Int
    let autoSnapshotDebounceMilliseconds: Int

    var signature: String {
        "\(contextID)|\(autoSnapshotEnabled ? 1 : 0)|\(autoSnapshotMaxDepth)|\(autoSnapshotDebounceMilliseconds)"
    }

    var autoSnapshotOptions: NSDictionary {
        [
            "enabled": NSNumber(value: autoSnapshotEnabled),
            "maxDepth": NSNumber(value: autoSnapshotMaxDepth),
            "debounce": NSNumber(value: autoSnapshotDebounceMilliseconds),
        ]
    }

    var scriptSource: String {
        let enabledLiteral = autoSnapshotEnabled ? "true" : "false"
        return """
        (function() {
            /* \(domAgentBootstrapScriptMarker) */
            const bootstrap = {
                contextID: \(contextID),
                autoSnapshot: {
                    enabled: \(enabledLiteral),
                    maxDepth: \(autoSnapshotMaxDepth),
                    debounce: \(autoSnapshotDebounceMilliseconds)
                }
            };
            Object.defineProperty(window, "\(domAgentBootstrapWindowKey)", {
                value: bootstrap,
                configurable: true,
                writable: false,
                enumerable: false
            });
            if (
                window.webInspectorDOM &&
                typeof window.webInspectorDOM.bootstrap === "function"
            ) {
                window.webInspectorDOM.bootstrap(bootstrap);
            }
        })();
        """
    }
}

@MainActor
public final class DOMPageBridge: NSObject {
    package enum MutationResult<Payload> {
        case applied(Payload)
        case contextInvalidated
        case failed(String?)
    }

    private enum HandlerName: String, CaseIterable {
        case snapshot = "webInspectorDOMSnapshot"
        case mutation = "webInspectorDOMMutations"
    }

    public var onEvent: (@MainActor (DOMPageEvent) -> Void)?

    private weak var webView: WKWebView?
    private var configuration: DOMConfiguration
    private var currentContextID: DOMContextID?
    private var documentURL: String?
    private var autoSnapshotEnabled = false

    private let bridgeWorld: WKContentWorld
    private let controllerStateRegistry: WIUserContentControllerStateRegistry
    private let installDOMBridgeScript: DOMBridgeScriptInstaller

    package var attachedWebView: WKWebView? {
        webView
    }

    package convenience init(configuration: DOMConfiguration) {
        self.init(
            configuration: configuration,
            controllerStateRegistry: .shared,
            installDOMBridgeScript: DOMPageBridge.evaluateDOMBridgeScript
        )
    }

    package init(
        configuration: DOMConfiguration,
        controllerStateRegistry: WIUserContentControllerStateRegistry,
        installDOMBridgeScript: @escaping DOMBridgeScriptInstaller = DOMPageBridge.evaluateDOMBridgeScript
    ) {
        self.configuration = configuration
        self.controllerStateRegistry = controllerStateRegistry
        self.installDOMBridgeScript = installDOMBridgeScript
        self.bridgeWorld = WISPIContentWorldProvider.bridgeWorld()
    }

    isolated deinit {
        tearDownPageWebViewForDeinit()
    }

    public func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
    }

    func tearDownForDeinit() {
        tearDownPageWebViewForDeinit()
    }
}

extension DOMPageBridge: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else {
            return
        }
        guard let handler = HandlerName(rawValue: message.name) else {
            return
        }
        guard let payload = message.body as? NSDictionary,
              let bundle = payload["bundle"]
        else {
            return
        }

        let contextID =
            (payload["contextID"] as? NSNumber)?.uint64Value
            ?? (payload["contextID"] as? UInt64)
            ?? currentContextID
            ?? 0
        let eventPayload: AnySendablePayload
        if let rawJSON = bundle as? String {
            eventPayload = AnySendablePayload(rawJSON)
        } else {
            eventPayload = AnySendablePayload(bundle)
        }

        switch handler {
        case .snapshot:
            onEvent?(.snapshot(payload: eventPayload, contextID: contextID))
        case .mutation:
            onEvent?(.mutations(payload: eventPayload, contextID: contextID))
        }
    }
}

extension DOMPageBridge {
    package func attach(to webView: WKWebView) {
        guard self.webView !== webView else {
            return
        }
        if let currentWebView = self.webView {
            detachMessageHandlers(from: currentWebView)
        }
        self.webView = webView
        registerMessageHandlers(on: webView)
    }

    package func detach() async {
        guard let webView else {
            currentContextID = nil
            documentURL = nil
            return
        }
        detachMessageHandlers(from: webView)
        self.webView = nil
        currentContextID = nil
        documentURL = nil
        await performDetachCleanup(on: webView)
    }

    package func installOrUpdateBootstrap(
        on webView: WKWebView,
        contextID: DOMContextID,
        configuration: DOMConfiguration? = nil,
        autoSnapshotEnabled: Bool
    ) async {
        if let configuration {
            updateConfiguration(configuration)
        }
        attach(to: webView)
        currentContextID = contextID
        self.autoSnapshotEnabled = autoSnapshotEnabled
        await installDOMAgentScriptIfNeeded(on: webView)
        await refreshBootstrap(on: webView)
        await configureAutoSnapshotIfPossible(on: webView)
    }

    package func readContext(on webView: WKWebView) async -> DOMContext? {
        guard self.webView === webView else {
            return nil
        }
        do {
            let rawResult = try await webView.callAsyncJavaScriptCompat(
                """
                return (function() {
                    const status = window.webInspectorDOM?.debugStatus?.();
                    if (!status || typeof status !== "object") {
                        return null;
                    }
                    return {
                        contextID: typeof status.contextID === "number" ? status.contextID : null,
                        documentURL: typeof status.documentURL === "string" ? status.documentURL : null
                    };
                })();
                """,
                arguments: [:],
                in: nil,
                contentWorld: bridgeWorld
            )
            guard let context = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any]),
                  let contextID = (context["contextID"] as? NSNumber)?.uint64Value ?? (context["contextID"] as? UInt64)
            else {
                return nil
            }
            let documentURL = normalizedDocumentURL(context["documentURL"] as? String)
            self.currentContextID = contextID
            self.documentURL = documentURL
            return DOMContext(contextID: contextID, documentURL: documentURL)
        } catch {
            domLogger.debug("read context skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    package func beginSelectionMode() async throws -> DOMSelectionResult {
        let webView = try requireWebView()
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            "return window.webInspectorDOM.startSelection()",
            arguments: [:],
            in: nil,
            contentWorld: bridgeWorld
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(DOMSelectionResult.self, from: data)
    }

    package func cancelSelectionMode() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM?.cancelSelection?.()",
            contentWorld: bridgeWorld
        )
    }

    package func highlight(nodeId: Int, reveal: Bool = true) async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM?.highlightNode?.(target, expectedContextID, reveal)",
            arguments: [
                "target": DOMRequestNodeTarget.local(UInt64(max(0, nodeId))).jsArgument as Any,
                "expectedContextID": currentContextID as Any,
                "reveal": reveal,
            ],
            contentWorld: bridgeWorld
        )
    }

    package func hideHighlight() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM?.clearHighlight?.(expectedContextID)",
            arguments: ["expectedContextID": currentContextID as Any],
            contentWorld: bridgeWorld
        )
    }

    package func captureSnapshotEnvelope(
        maxDepth: Int,
        selectionRestorePath: [Int]? = nil,
        selectionRestoreLocalID: UInt64? = nil,
        selectionRestoreBackendNodeID: Int? = nil
    ) async throws -> Any {
        let webView = try requireWebView()
        let selectionRestoreTargetProvided =
            selectionRestorePath != nil
            || selectionRestoreLocalID != nil
            || selectionRestoreBackendNodeID != nil
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            """
            if (selectionRestoreTargetProvided) {
                window.webInspectorDOM?.setPendingSelectionRestoreTarget?.(
                    selectionRestorePath,
                    selectionRestoreLocalID,
                    selectionRestoreBackendNodeID
                );
            }
            if (window.webInspectorDOM?.captureSnapshotEnvelope) {
                return window.webInspectorDOM.captureSnapshotEnvelope(maxDepth);
            }
            return window.webInspectorDOM?.captureSnapshot?.(maxDepth) ?? null;
            """,
            arguments: [
                "maxDepth": max(1, maxDepth),
                "selectionRestoreTargetProvided": selectionRestoreTargetProvided,
                "selectionRestorePath": selectionRestorePath as Any,
                "selectionRestoreLocalID": selectionRestoreLocalID as Any,
                "selectionRestoreBackendNodeID": selectionRestoreBackendNodeID as Any,
            ],
            in: nil,
            contentWorld: bridgeWorld
        )
        return unwrapOptionalPayload(rawResult)
    }

    package func captureSubtreeEnvelope(target: DOMRequestNodeTarget, maxDepth: Int) async throws -> Any {
        let webView = try requireWebView()
        guard let targetArgument = target.jsArgument else {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            """
            if (window.webInspectorDOM?.captureSubtreeEnvelope) {
                return window.webInspectorDOM.captureSubtreeEnvelope(target, maxDepth);
            }
            return window.webInspectorDOM?.captureSubtree?.(target, maxDepth) ?? "";
            """,
            arguments: [
                "target": targetArgument,
                "maxDepth": max(1, maxDepth),
            ],
            in: nil,
            contentWorld: bridgeWorld
        )
        let payload = unwrapOptionalPayload(rawResult)
        if let string = payload as? String, string.isEmpty {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        return payload
    }

    package func removeNode(
        target: DOMRequestNodeTarget,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Void> {
        await executeVoidMutation(
            functionName: "removeNode",
            target: target,
            name: nil,
            value: nil,
            undoToken: nil,
            expectedContextID: expectedContextID
        )
    }

    package func removeNodeWithUndo(
        target: DOMRequestNodeTarget,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Int> {
        await executeUndoMutation(
            functionName: "removeNodeWithUndo",
            target: target,
            undoToken: nil,
            expectedContextID: expectedContextID
        )
    }

    package func undoRemoveNode(
        undoToken: Int,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Void> {
        await executeVoidMutation(
            functionName: "undoRemoveNode",
            target: nil,
            name: nil,
            value: nil,
            undoToken: undoToken,
            expectedContextID: expectedContextID
        )
    }

    package func redoRemoveNode(
        undoToken: Int,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Void> {
        await executeVoidMutation(
            functionName: "redoRemoveNode",
            target: nil,
            name: nil,
            value: nil,
            undoToken: undoToken,
            expectedContextID: expectedContextID
        )
    }

    package func setAttribute(
        target: DOMRequestNodeTarget,
        name: String,
        value: String,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Void> {
        await executeVoidMutation(
            functionName: "setAttributeForNode",
            target: target,
            name: name,
            value: value,
            undoToken: nil,
            expectedContextID: expectedContextID
        )
    }

    package func removeAttribute(
        target: DOMRequestNodeTarget,
        name: String,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Void> {
        await executeVoidMutation(
            functionName: "removeAttributeForNode",
            target: target,
            name: name,
            value: nil,
            undoToken: nil,
            expectedContextID: expectedContextID
        )
    }

    package func selectionCopyText(target: DOMRequestNodeTarget, kind: DOMSelectionCopyKind) async throws -> String {
        let webView = try requireWebView()
        guard let targetArgument = target.jsArgument else {
            return ""
        }
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            "return window.webInspectorDOM?.\(kind.jsFunction)?.(target) ?? \"\"",
            arguments: ["target": targetArgument],
            in: nil,
            contentWorld: bridgeWorld
        )
        return rawResult as? String ?? ""
    }
}

private extension DOMPageBridge {
    static func evaluateDOMBridgeScript(
        on webView: WKWebView,
        scriptSource: String,
        contentWorld: WKContentWorld
    ) async throws {
        try await webView.callAsyncVoidJavaScript(
            scriptSource,
            contentWorld: contentWorld
        )
    }

    func requireWebView() throws -> WKWebView {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        return webView
    }

    func currentBootstrapConfiguration() -> DOMBootstrapConfiguration {
        DOMBootstrapConfiguration(
            contextID: currentContextID ?? 0,
            autoSnapshotEnabled: autoSnapshotEnabled,
            autoSnapshotMaxDepth: max(1, configuration.snapshotDepth),
            autoSnapshotDebounceMilliseconds: max(50, Int(configuration.autoUpdateDebounce * 1000))
        )
    }

    func makeBootstrapUserScript(_ bootstrap: DOMBootstrapConfiguration) -> WKUserScript {
        WKUserScript(
            source: bootstrap.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: bridgeWorld
        )
    }

    func replaceBootstrapUserScript(
        on controller: WKUserContentController,
        with bootstrapScript: WKUserScript
    ) {
        var replaced = false
        let updatedScripts = controller.userScripts.compactMap { script in
            guard script.source.contains(domAgentBootstrapScriptMarker) else {
                return script
            }
            guard !replaced else {
                return nil
            }
            replaced = true
            return bootstrapScript
        }

        controller.removeAllUserScripts()
        if !replaced {
            controller.addUserScript(bootstrapScript)
        }
        updatedScripts.forEach { controller.addUserScript($0) }
    }

    func installDOMAgentScriptIfNeeded(on webView: WKWebView) async {
        let controller = webView.configuration.userContentController
        if controllerStateRegistry.domBridgeScriptInstalled(on: controller) {
            return
        }

        let bootstrap = currentBootstrapConfiguration()
        let scriptSource: String
        do {
            scriptSource = try WebInspectorScripts.domAgent()
        } catch {
            domLogger.error("failed to load DOM agent: \(error.localizedDescription, privacy: .public)")
            return
        }

        controller.addUserScript(makeBootstrapUserScript(bootstrap))
        controllerStateRegistry.setDOMBootstrapSignature(bootstrap.signature, on: controller)
        controller.addUserScript(
            WKUserScript(
                source: scriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: bridgeWorld
            )
        )
        controllerStateRegistry.setDOMBridgeScriptInstalled(true, on: controller)

        do {
            try await webView.callAsyncVoidJavaScript(
                bootstrap.scriptSource,
                contentWorld: bridgeWorld
            )
            try await installDOMBridgeScript(webView, scriptSource, bridgeWorld)
        } catch {
            domLogger.error("failed to evaluate DOM agent: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshBootstrap(on webView: WKWebView) async {
        guard self.webView === webView else {
            return
        }
        let controller = webView.configuration.userContentController
        let bootstrap = currentBootstrapConfiguration()
        if controllerStateRegistry.domBootstrapSignature(on: controller) != bootstrap.signature {
            replaceBootstrapUserScript(on: controller, with: makeBootstrapUserScript(bootstrap))
            controllerStateRegistry.setDOMBootstrapSignature(bootstrap.signature, on: controller)
        }

        do {
            try await webView.callAsyncVoidJavaScript(
                bootstrap.scriptSource,
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("refresh bootstrap skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func configureAutoSnapshotIfPossible(on webView: WKWebView) async {
        let options = currentBootstrapConfiguration().autoSnapshotOptions
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM?.configureAutoSnapshot?.(options)",
                arguments: ["options": options],
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("configure auto snapshot skipped: \(error.localizedDescription, privacy: .public)")
        }
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
    }

    func performDetachCleanup(on webView: WKWebView) async {
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM?.detach?.()",
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("detach cleanup skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func tearDownPageWebViewForDeinit() {
        guard let webView else {
            return
        }
        webView.evaluateJavaScriptCompat(
            "window.webInspectorDOM?.detach?.()",
            in: nil,
            in: bridgeWorld,
            completionHandler: nil
        )
        detachMessageHandlers(from: webView)
    }

    func executeVoidMutation(
        functionName: String,
        target: DOMRequestNodeTarget?,
        name: String?,
        value: String?,
        undoToken: Int?,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Void> {
        let rawResult = await executeMutation(
            functionName: functionName,
            target: target,
            name: name,
            value: value,
            undoToken: undoToken,
            expectedContextID: expectedContextID
        )
        switch rawResult {
        case .applied:
            return .applied(())
        case .contextInvalidated:
            return .contextInvalidated
        case let .failed(message):
            return .failed(message)
        }
    }

    func executeUndoMutation(
        functionName: String,
        target: DOMRequestNodeTarget?,
        undoToken: Int?,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Int> {
        let rawResult = await executeMutation(
            functionName: functionName,
            target: target,
            name: nil,
            value: nil,
            undoToken: undoToken,
            expectedContextID: expectedContextID
        )
        guard case let .applied(payload) = rawResult else {
            switch rawResult {
            case .contextInvalidated:
                return .contextInvalidated
            case let .failed(message):
                return .failed(message)
            case .applied:
                return .failed("missing undo token")
            }
        }
        guard let dictionary = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]),
              let undoToken = (dictionary["undoToken"] as? NSNumber)?.intValue ?? (dictionary["undoToken"] as? Int)
        else {
            return .failed("missing undo token")
        }
        return .applied(undoToken)
    }

    func executeMutation(
        functionName: String,
        target: DOMRequestNodeTarget?,
        name: String?,
        value: String?,
        undoToken: Int?,
        expectedContextID: DOMContextID?
    ) async -> MutationResult<Any> {
        let webView: WKWebView
        do {
            webView = try requireWebView()
        } catch {
            return .failed(error.localizedDescription)
        }

        let targetArgument = target?.jsArgument
        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScriptCompat(
                mutationInvocationSource(functionName),
                arguments: [
                    "target": targetArgument as Any,
                    "name": name as Any,
                    "value": value as Any,
                    "undoToken": undoToken as Any,
                    "expectedContextID": expectedContextID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.error("\(functionName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }

        return parseMutationResult(rawResult)
    }

    func mutationInvocationSource(_ functionName: String) -> String {
        """
        return (function(target, name, value, undoToken, expectedContextID) {
            const fn = window.webInspectorDOM?.[\(String(reflecting: functionName))];
            if (typeof fn !== "function") {
                return { status: "failed", message: "missing mutation function" };
            }
            switch (\(String(reflecting: functionName))) {
            case "removeNode":
            case "removeNodeWithUndo":
                return fn(target, expectedContextID);
            case "undoRemoveNode":
            case "redoRemoveNode":
                return fn(undoToken, expectedContextID);
            case "setAttributeForNode":
                return fn(target, name, value, expectedContextID);
            case "removeAttributeForNode":
                return fn(target, name, expectedContextID);
            default:
                return { status: "failed", message: "unsupported mutation function" };
            }
        })(target, name, value, undoToken, expectedContextID);
        """
    }

    func parseMutationResult(_ rawResult: Any?) -> MutationResult<Any> {
        guard let payload = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any]),
              let status = payload["status"] as? String
        else {
            return .failed("invalid mutation payload")
        }
        switch status {
        case "applied":
            return .applied(payload)
        case "contextInvalidated":
            return .contextInvalidated
        default:
            return .failed(payload["message"] as? String)
        }
    }

    func serializePayload(_ payload: Any?) throws -> Data {
        let resolved = unwrapOptionalPayload(payload)
        if let string = resolved as? String {
            return Data(string.utf8)
        }
        if let dictionary = resolved as? NSDictionary {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = resolved as? NSArray {
            guard JSONSerialization.isValidJSONObject(array) else {
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }
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
}

private func normalizedDocumentURL(_ documentURL: String?) -> String? {
    guard let documentURL, !documentURL.isEmpty else {
        return nil
    }
    guard var components = URLComponents(string: documentURL) else {
        return documentURL
    }
    components.fragment = nil
    return components.string ?? documentURL
}

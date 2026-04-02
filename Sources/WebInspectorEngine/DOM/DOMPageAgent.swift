import Foundation
import OSLog
import WebKit
import WebInspectorScripts
import WebInspectorBridge

private let domLogger = Logger(subsystem: "WebInspectorKit", category: "DOMPageAgent")
private let domAgentPresenceProbeScript: String = """
(function() { /* webInspectorDOM */ })();
"""
private let autoSnapshotConfigureRetryCount = 20
private let autoSnapshotConfigureRetryDelayNanoseconds: UInt64 = 50_000_000
private let pageEpochApplyRetryDelayNanoseconds: UInt64 = 50_000_000
private let documentScopeSyncRetryLimit = 100
private let unavailableBridgeSentinel = "__wi_bridge_unavailable__"
private typealias DOMBridgeScriptInstaller = @MainActor (WKWebView, String, WKContentWorld) async throws -> Void

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

        var functionName: String {
            switch self {
            case .highlight:
                return "highlightNodeHandle"
            }
        }
    }

    public weak var sink: (any DOMBundleSink)?
    weak var webView: WKWebView?
    private var configuration: DOMConfiguration
    private var pageEpoch = 0
    private var documentScopeID: DOMDocumentScopeID = 0

    private let runtime: WISPIRuntime
    private let bridgeWorld: WKContentWorld
    private let controllerStateRegistry: WIUserContentControllerStateRegistry
    private let installDOMBridgeScript: DOMBridgeScriptInstaller
    private let handleCache = WIJSHandleCache(capacity: 128)
    private var bridgeMode: WIBridgeMode
    private var bridgeModeLocked = false
    private var pageEpochApplyGeneration: UInt64 = 0
    private var pageEpochSyncTask: Task<Void, Never>?
    private var pageEpochSyncTaskGeneration: UInt64?
#if DEBUG
    package var testSetAttributeInterposer: (@MainActor (
        Int,
        String,
        String,
        Int?,
        DOMDocumentScopeID?,
        @escaping @MainActor @Sendable () async -> DOMMutationExecutionResult<Void>
    ) async -> DOMMutationExecutionResult<Void>)?
    package var testDocumentScopeSyncRetryLimitOverride: Int?
#endif

    package var currentBridgeMode: WIBridgeMode {
        bridgeMode
    }

    package convenience init(configuration: DOMConfiguration) {
        self.init(
            configuration: configuration,
            controllerStateRegistry: .shared,
            installDOMBridgeScript: DOMPageAgent.evaluateDOMBridgeScript
        )
    }

    package init(
        configuration: DOMConfiguration,
        controllerStateRegistry: WIUserContentControllerStateRegistry,
        installDOMBridgeScript: @escaping @MainActor (WKWebView, String, WKContentWorld) async throws -> Void = DOMPageAgent.evaluateDOMBridgeScript
    ) {
        self.configuration = configuration
        runtime = .shared
        self.controllerStateRegistry = controllerStateRegistry
        self.installDOMBridgeScript = installDOMBridgeScript
        bridgeMode = runtime.startupMode()
        bridgeWorld = WISPIContentWorldProvider.bridgeWorld(runtime: runtime)
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

    private static func evaluateDOMBridgeScript(
        on webView: WKWebView,
        scriptSource: String,
        contentWorld: WKContentWorld
    ) async throws {
        try await webView.callAsyncVoidJavaScript(
            scriptSource,
            contentWorld: contentWorld
        )
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
        let payloadPageEpoch = (payload["pageEpoch"] as? NSNumber)?.intValue
            ?? (payload["pageEpoch"] as? Int)
            ?? pageEpoch
        let payloadDocumentScopeID = (payload["documentScopeID"] as? NSNumber)?.uint64Value
            ?? (payload["documentScopeID"] as? UInt64)
            ?? documentScopeID

        if let rawJSON = bundle as? String, !rawJSON.isEmpty {
            sink?.domDidEmit(
                bundle: DOMBundle(
                    rawJSON: rawJSON,
                    pageEpoch: payloadPageEpoch,
                    documentScopeID: payloadDocumentScopeID
                )
            )
            return
        }

        sink?.domDidEmit(
            bundle: DOMBundle(
                objectEnvelope: bundle,
                pageEpoch: payloadPageEpoch,
                documentScopeID: payloadDocumentScopeID
            )
        )
    }
}

// MARK: - Selection / Highlight

extension DOMPageAgent {
    package func beginSelectionMode() async throws -> SelectionModeResult {
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

    package func cancelSelectionMode() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.cancelSelection()",
            contentWorld: bridgeWorld
        )
    }

    package func highlight(nodeId: Int) async {
        guard let webView else {
            return
        }
        if await runHandleCommand(.highlight, nodeId: nodeId, on: webView, expectedPageEpoch: pageEpoch) {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.highlightNode(identifier, expectedPageEpoch)",
            arguments: [
                "identifier": nodeId,
                "expectedPageEpoch": pageEpoch,
            ],
            contentWorld: bridgeWorld
        )
    }

    package func hideHighlight() async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM && window.webInspectorDOM.clearHighlight(expectedPageEpoch);",
            arguments: ["expectedPageEpoch": pageEpoch],
            contentWorld: bridgeWorld
        )
    }
}

// MARK: - DOM Snapshot

extension DOMPageAgent {
    package func captureSnapshot(maxDepth: Int) async throws -> String {
        let payload = try await snapshotPayload(maxDepth: maxDepth, preferEnvelope: false)
        return try jsonString(from: payload)
    }

    package func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        let payload = try await subtreePayload(nodeId: nodeId, maxDepth: maxDepth, preferEnvelope: false)
        let json = try jsonString(from: payload)
        guard !json.isEmpty else {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        return json
    }

    package func matchedStyles(nodeId: Int, maxRules: Int = 0) async throws -> DOMMatchedStylesPayload {
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

    package func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        try await snapshotPayload(maxDepth: maxDepth, preferEnvelope: bridgeMode != .legacyJSON)
    }

    package func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        try await subtreePayload(nodeId: nodeId, maxDepth: maxDepth, preferEnvelope: bridgeMode != .legacyJSON)
    }
}

// MARK: - DOM Mutations

extension DOMPageAgent {
    package func removeNode(
        nodeId: Int,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        guard let webView else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawResult = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.removeNode(identifier, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "identifier": nodeId,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            let result = parseMutationExecutionResult(rawResult)
            if case .applied = result {
                handleCache.removeHandle(for: nodeId)
            }
            return result
        } catch {
            domLogger.error("remove node failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    package func removeNodeWithUndo(
        nodeId: Int,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Int> {
        guard let webView else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.removeNodeWithUndo(identifier, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "identifier": nodeId,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            let result = parseUndoMutationExecutionResult(rawValue)
            if case .applied = result {
                handleCache.removeHandle(for: nodeId)
            }
            return result
        } catch {
            domLogger.error("remove node with undo failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    package func undoRemoveNode(
        undoToken: Int,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        guard let webView else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.undoRemoveNode(token, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "token": undoToken,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            return parseMutationExecutionResult(rawValue)
        } catch {
            domLogger.error("undo remove node failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    package func redoRemoveNode(
        undoToken: Int,
        nodeId: Int? = nil,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        guard let webView else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.redoRemoveNode(token, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "token": undoToken,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            let result = parseMutationExecutionResult(rawValue)
            if case .applied = result, let nodeId {
                handleCache.removeHandle(for: nodeId)
            }
            return result
        } catch {
            domLogger.error("redo remove node failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    package func setAttribute(
        nodeId: Int,
        name: String,
        value: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        let performMutation = { @MainActor @Sendable [weak self] () async -> DOMMutationExecutionResult<Void> in
            guard Task.isCancelled == false else {
                return .ignoredStaleContext
            }
            guard let self, let webView = self.webView else {
                return .failed
            }
            await self.waitForPreparedPageContextSyncIfNeeded()
            guard Task.isCancelled == false else {
                return .ignoredStaleContext
            }
            do {
                let rawValue = try await webView.callAsyncJavaScript(
                    "return window.webInspectorDOM.setAttributeForNode(identifier, name, value, expectedPageEpoch, expectedDocumentScopeID)",
                    arguments: [
                        "identifier": nodeId,
                        "name": name,
                        "value": value,
                        "expectedPageEpoch": expectedPageEpoch as Any,
                        "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                    ],
                    in: nil,
                    contentWorld: self.bridgeWorld
                )
                return self.parseMutationExecutionResult(rawValue)
            } catch {
                domLogger.error("set attribute failed: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        }
#if DEBUG
        if let testSetAttributeInterposer {
            return await testSetAttributeInterposer(
                nodeId,
                name,
                value,
                expectedPageEpoch,
                expectedDocumentScopeID,
                performMutation
            )
        }
#endif
        return await performMutation()
    }

    package func removeAttribute(
        nodeId: Int,
        name: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        guard let webView else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawValue = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOM.removeAttributeForNode(identifier, name, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "identifier": nodeId,
                    "name": name,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            return parseMutationExecutionResult(rawValue)
        } catch {
            domLogger.error("remove attribute failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    package func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await evaluateStringScript(
            """
            return window.webInspectorDOM?.\(kind.jsFunction)(identifier) ?? ""
            """,
            nodeId: nodeId
        )
    }
}

// MARK: - Auto Snapshot

extension DOMPageAgent {
    package func setAutoSnapshot(enabled: Bool) async {
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
    package func waitForPreparedPageContextSyncIfNeeded() async {
        while let pageEpochSyncTask {
            let generation = pageEpochSyncTaskGeneration
            if let generation, generation != pageEpochApplyGeneration {
                clearPreparedPageContextSyncTaskIfCurrent(generation: generation)
                continue
            }
            await pageEpochSyncTask.value
            if let generation {
                clearPreparedPageContextSyncTaskIfCurrent(generation: generation)
            } else {
                self.pageEpochSyncTask = nil
                self.pageEpochSyncTaskGeneration = nil
            }
        }
    }

    package func syncDocumentScopeIDIfNeeded(
        _ documentScopeID: DOMDocumentScopeID,
        on webView: WKWebView,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
        let retryLimit: Int
#if DEBUG
        retryLimit = max(1, testDocumentScopeSyncRetryLimitOverride ?? documentScopeSyncRetryLimit)
#else
        retryLimit = documentScopeSyncRetryLimit
#endif
        var remainingStallRetries = retryLimit
        var lastObservedDocumentScopeID = self.documentScopeID
        func consumeRetry(progressedForward: Bool) -> Bool {
            if progressedForward {
                remainingStallRetries = retryLimit
                return true
            }
            remainingStallRetries -= 1
            return remainingStallRetries > 0
        }
        while Task.isCancelled == false {
            guard self.webView === webView else {
                return false
            }
            if let expectedPageEpoch, self.pageEpoch != expectedPageEpoch {
                return false
            }
            if self.documentScopeID >= documentScopeID {
                let didRefreshContext = await refreshCachedPageContextFromPageIfPossible(on: webView)
                guard self.webView === webView else {
                    return false
                }
                if let expectedPageEpoch, self.pageEpoch != expectedPageEpoch {
                    return false
                }
                if didRefreshContext {
                    if self.documentScopeID >= documentScopeID {
                        return true
                    }
                    let didProgressForward = self.documentScopeID > lastObservedDocumentScopeID
                    if didProgressForward {
                        lastObservedDocumentScopeID = self.documentScopeID
                    }
                    if !consumeRetry(progressedForward: didProgressForward) {
                        return false
                    }
                } else {
                    if !consumeRetry(progressedForward: false) {
                        return false
                    }
                }
            }
            let didApply = await applyDocumentScopeID(documentScopeID, on: webView)
            if didApply || self.documentScopeID >= documentScopeID {
                return true
            }
            let didRefreshContext = await refreshCachedPageContextFromPageIfPossible(on: webView)
            guard self.webView === webView else {
                return false
            }
            if let expectedPageEpoch, self.pageEpoch != expectedPageEpoch {
                return false
            }
            if didRefreshContext {
                if self.documentScopeID >= documentScopeID {
                    return true
                }
                let didProgressForward = self.documentScopeID > lastObservedDocumentScopeID
                if didProgressForward {
                    lastObservedDocumentScopeID = self.documentScopeID
                }
                if !consumeRetry(progressedForward: didProgressForward) {
                    return false
                }
            } else {
                if !consumeRetry(progressedForward: false) {
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: pageEpochApplyRetryDelayNanoseconds)
        }
        return false
    }

    func reloadPage() {
        webView?.reload()
    }

    func reloadPageAndWaitForPreparedPageEpochSync(
        _ preparedPageEpoch: Int?,
        documentScopeID: DOMDocumentScopeID? = nil
    ) async {
        guard let webView else {
            return
        }
        let generation = beginPageEpochApplyGeneration()
        reloadPage()
        guard let preparedPageEpoch else {
            return
        }
        await waitForReloadToSettle(on: webView, generation: generation)
        await syncPreparedPageContext(
            pageEpoch: preparedPageEpoch,
            documentScopeID: documentScopeID,
            on: webView,
            generation: generation
        )
    }

    func ensureDOMAgentScriptInstalled(on webView: WKWebView) async {
        await ensureDOMAgentScriptInstalled(on: webView, pageEpoch: nil, documentScopeID: nil)
    }

    package func ensureDOMAgentScriptInstalled(
        on webView: WKWebView,
        pageEpoch: Int?,
        documentScopeID: DOMDocumentScopeID? = nil
    ) async {
        await installDOMAgentScriptIfNeeded(on: webView)
        await refreshCachedPageContextFromPageIfPossible(on: webView)
        if pageEpoch != nil || documentScopeID != nil {
            let generation = beginPageEpochApplyGeneration()
            let didApply = await applyPreparedPageContext(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID,
                on: webView,
                generation: generation
            )
            if didApply == false {
                schedulePreparedPageContextSync(
                    pageEpoch: pageEpoch,
                    documentScopeID: documentScopeID,
                    on: webView,
                    generation: generation
                )
            }
        }
    }

    func detachPageWebViewAndWaitForCleanup() async {
        let detachedWebView = webView
        detachPageWebView()
        guard let detachedWebView else {
            return
        }
        await performDetachCleanup(on: detachedWebView)
    }

    func willDetachPageWebView(_ webView: WKWebView) {
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        resolveBridgeModeIfNeeded(with: webView)
        registerMessageHandlers(on: webView)
    }

    func didClearPageWebView() {
        _ = beginPageEpochApplyGeneration()
        handleCache.clear()
    }
}

// MARK: - Private helpers

private extension DOMPageAgent {
    func beginPageEpochApplyGeneration() -> UInt64 {
        pageEpochSyncTask?.cancel()
        pageEpochSyncTask = nil
        pageEpochSyncTaskGeneration = nil
        pageEpochApplyGeneration += 1
        return pageEpochApplyGeneration
    }

    func clearPreparedPageContextSyncTaskIfCurrent(generation: UInt64) {
        guard pageEpochSyncTaskGeneration == generation else {
            return
        }
        pageEpochSyncTask = nil
        pageEpochSyncTaskGeneration = nil
    }

    func schedulePreparedPageContextSync(
        pageEpoch: Int?,
        documentScopeID: DOMDocumentScopeID?,
        on webView: WKWebView,
        generation: UInt64
    ) {
        pageEpochSyncTaskGeneration = generation
        pageEpochSyncTask = Task { @MainActor [weak self, weak webView] in
            defer {
                self?.clearPreparedPageContextSyncTaskIfCurrent(generation: generation)
            }
            guard let self, let webView else {
                return
            }
            await self.syncPreparedPageContext(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID,
                on: webView,
                generation: generation
            )
        }
    }

    func waitForReloadToSettle(on webView: WKWebView, generation: UInt64) async {
        var sawLoading = webView.isLoading
        var idlePollCount = sawLoading ? 0 : 1
        while self.webView === webView, self.pageEpochApplyGeneration == generation {
            if webView.isLoading {
                sawLoading = true
                idlePollCount = 0
            } else if sawLoading || idlePollCount >= 2 {
                return
            } else {
                idlePollCount += 1
            }
            try? await Task.sleep(nanoseconds: pageEpochApplyRetryDelayNanoseconds)
        }
    }

    func syncPreparedPageContext(
        pageEpoch: Int?,
        documentScopeID: DOMDocumentScopeID?,
        on webView: WKWebView,
        generation: UInt64
    ) async {
        while Task.isCancelled == false {
            let didApply = await self.applyPreparedPageContext(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID,
                on: webView,
                generation: generation
            )
            if didApply {
                return
            }
            try? await Task.sleep(nanoseconds: pageEpochApplyRetryDelayNanoseconds)
        }
    }

    @discardableResult
    func refreshCachedPageContextFromPageIfPossible(on webView: WKWebView) async -> Bool {
        guard self.webView === webView else {
            return false
        }
        do {
            let rawResult = try await webView.callAsyncJavaScript(
                """
                return (function() {
                    if (!window.webInspectorDOM || typeof window.webInspectorDOM.debugStatus !== "function") {
                        return null;
                    }
                    const status = window.webInspectorDOM.debugStatus();
                    if (!status || typeof status !== "object") {
                        return null;
                    }
                    return {
                        pageEpoch: typeof status.pageEpoch === "number" ? status.pageEpoch : null,
                        documentScopeID: typeof status.documentScopeID === "number" ? status.documentScopeID : null
                    };
                })();
                """,
                arguments: [:],
                in: nil,
                contentWorld: bridgeWorld
            )
            let appliedContext = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any])
            let appliedEpoch = (appliedContext?["pageEpoch"] as? Int) ?? (appliedContext?["pageEpoch"] as? NSNumber)?.intValue
            let appliedDocumentScopeID = (appliedContext?["documentScopeID"] as? UInt64) ?? (appliedContext?["documentScopeID"] as? NSNumber)?.uint64Value
            guard appliedEpoch != nil || appliedDocumentScopeID != nil else {
                return false
            }
            if let appliedEpoch, self.pageEpoch != appliedEpoch {
                handleCache.clear()
                self.pageEpoch = appliedEpoch
            }
            if let appliedDocumentScopeID, self.documentScopeID != appliedDocumentScopeID {
                handleCache.clear()
                self.documentScopeID = appliedDocumentScopeID
            }
            return true
        } catch {
            domLogger.debug("refresh cached page context skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func applyDocumentScopeID(
        _ documentScopeID: DOMDocumentScopeID,
        on webView: WKWebView
    ) async -> Bool {
        guard self.webView === webView else {
            return true
        }
        do {
            let rawResult = try await webView.callAsyncJavaScript(
                """
                return (function(documentScopeID) {
                    if (!window.webInspectorDOM || typeof window.webInspectorDOM.setDocumentScopeID !== "function") {
                        return null;
                    }
                    window.webInspectorDOM.setDocumentScopeID(documentScopeID);
                    if (typeof window.webInspectorDOM.debugStatus !== "function") {
                        return null;
                    }
                    const status = window.webInspectorDOM.debugStatus();
                    return status && typeof status.documentScopeID === "number"
                        ? status.documentScopeID
                        : null;
                })(documentScopeID);
                """,
                arguments: ["documentScopeID": documentScopeID as Any],
                in: nil,
                contentWorld: bridgeWorld
            )
            let appliedDocumentScopeID = (rawResult as? UInt64) ?? (rawResult as? NSNumber)?.uint64Value
            guard let appliedDocumentScopeID, appliedDocumentScopeID == documentScopeID else {
                return false
            }
            if self.documentScopeID != appliedDocumentScopeID {
                handleCache.clear()
                self.documentScopeID = appliedDocumentScopeID
            }
            return true
        } catch {
            domLogger.debug("set document scope skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func applyPreparedPageContext(
        pageEpoch epoch: Int?,
        documentScopeID: DOMDocumentScopeID?,
        on webView: WKWebView,
        generation: UInt64
    ) async -> Bool {
        guard self.webView === webView, self.pageEpochApplyGeneration == generation else {
            return true
        }
        do {
            let rawResult = try await webView.callAsyncJavaScript(
                """
                return (function(epoch, documentScopeID) {
                    if (!window.webInspectorDOM) {
                        return null;
                    }
                    if (typeof epoch === "number" && typeof window.webInspectorDOM.setPageEpoch === "function") {
                        window.webInspectorDOM.setPageEpoch(epoch);
                    }
                    if (typeof documentScopeID === "number" && typeof window.webInspectorDOM.setDocumentScopeID === "function") {
                        window.webInspectorDOM.setDocumentScopeID(documentScopeID);
                    }
                    if (typeof window.webInspectorDOM.debugStatus !== "function") {
                        return null;
                    }
                    const status = window.webInspectorDOM.debugStatus();
                    if (!status || typeof status !== "object") {
                        return null;
                    }
                    return {
                        pageEpoch: typeof status.pageEpoch === "number" ? status.pageEpoch : null,
                        documentScopeID: typeof status.documentScopeID === "number" ? status.documentScopeID : null
                    };
                })(epoch, documentScopeID);
                """,
                arguments: [
                    "epoch": epoch as Any,
                    "documentScopeID": documentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            let appliedContext = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any])
            let appliedEpoch = (appliedContext?["pageEpoch"] as? Int) ?? (appliedContext?["pageEpoch"] as? NSNumber)?.intValue
            let appliedDocumentScopeID = (appliedContext?["documentScopeID"] as? UInt64) ?? (appliedContext?["documentScopeID"] as? NSNumber)?.uint64Value
            let pageEpochMatches = epoch == nil || ((appliedEpoch ?? .min) >= epoch!)
            let documentScopeMatches = documentScopeID == nil || ((appliedDocumentScopeID ?? 0) >= documentScopeID!)
            guard (appliedEpoch != nil || appliedDocumentScopeID != nil), pageEpochMatches, documentScopeMatches else {
                return false
            }
            guard self.webView === webView, self.pageEpochApplyGeneration == generation else {
                return true
            }
            if let appliedEpoch, self.pageEpoch != appliedEpoch {
                handleCache.clear()
                self.pageEpoch = appliedEpoch
            }
            if let appliedDocumentScopeID, self.documentScopeID != appliedDocumentScopeID {
                handleCache.clear()
                self.documentScopeID = appliedDocumentScopeID
            }
            clearPreparedPageContextSyncTaskIfCurrent(generation: generation)
            return true
        } catch {
            domLogger.debug("set page context skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func performDetachCleanup(on webView: WKWebView) async {
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM && window.webInspectorDOM.detach && window.webInspectorDOM.detach();",
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
        webView.evaluateJavaScript(
            "window.webInspectorDOM && window.webInspectorDOM.detach && window.webInspectorDOM.detach();",
            in: nil,
            in: bridgeWorld,
            completionHandler: nil
        )
        detachMessageHandlers(from: webView)
        self.webView = nil
        handleCache.clear()
    }

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

    func installDOMAgentScriptIfNeeded(on webView: WKWebView) async {
        let controller = webView.configuration.userContentController
        if controllerStateRegistry.domBridgeScriptInstalled(on: controller) {
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
        controllerStateRegistry.setDOMBridgeScriptInstalled(true, on: controller)

        do {
            try await installDOMBridgeScript(webView, scriptSource, bridgeWorld)
        } catch {
            domLogger.error(
                "failed to evaluate DOM agent script after registration: \(error.localizedDescription, privacy: .public)"
            )
        }
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

    private func runHandleCommand(
        _ command: HandleCommand,
        nodeId: Int,
        on webView: WKWebView,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
        guard bridgeMode != .legacyJSON else {
            return false
        }
        guard let handle = await resolveHandle(for: nodeId, on: webView) else {
            return false
        }

        do {
            let invocation = makeHandleInvocation(
                command: command,
                handle: handle,
                expectedPageEpoch: expectedPageEpoch
            )
            let rawResult = try await webView.callAsyncJavaScript(
                invocation.script,
                arguments: invocation.arguments,
                in: nil,
                contentWorld: bridgeWorld
            )

            if let sentinel = rawResult as? String, sentinel == unavailableBridgeSentinel {
                lockToLegacyMode("selector_missing=\(command.functionName)")
                return false
            }

            let succeeded = (rawResult as? Bool) ?? (rawResult as? NSNumber)?.boolValue ?? false
            if !succeeded {
                return false
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
                    "unavailable": unavailableBridgeSentinel,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )

            if let sentinel = rawResult as? String, sentinel == unavailableBridgeSentinel {
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

    private func makeHandleInvocation(
        command: HandleCommand,
        handle: AnyObject,
        expectedPageEpoch: Int?
    ) -> (script: String, arguments: [String: Any]) {
        var arguments: [String: Any] = [
            "handle": handle,
            "unavailable": unavailableBridgeSentinel,
        ]
        if let expectedPageEpoch {
            arguments["expectedPageEpoch"] = expectedPageEpoch
        }

        let script: String
        switch command {
        case .highlight:
            script = """
            if (!window.webInspectorDOM || typeof window.webInspectorDOM.highlightNodeHandle !== "function") {
                return unavailable;
            }
            return window.webInspectorDOM.highlightNodeHandle(handle, expectedPageEpoch);
            """
        }

        return (script: script, arguments: arguments)
    }

    func parseMutationExecutionResult(_ rawResult: Any) -> DOMMutationExecutionResult<Void> {
        let payload = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any])
        let status = payload?["status"] as? String
        switch status {
        case "applied":
            return .applied(())
        case "ignoredStaleContext":
            return .ignoredStaleContext
        default:
            return .failed
        }
    }

    func parseUndoMutationExecutionResult(_ rawResult: Any) -> DOMMutationExecutionResult<Int> {
        let payload = rawResult as? [String: Any] ?? (rawResult as? NSDictionary as? [String: Any])
        let status = payload?["status"] as? String
        switch status {
        case "applied":
            if let undoToken = (payload?["undoToken"] as? Int) ?? (payload?["undoToken"] as? NSNumber)?.intValue {
                return .applied(undoToken)
            }
            return .failed
        case "ignoredStaleContext":
            return .ignoredStaleContext
        default:
            return .failed
        }
    }
}

#if DEBUG
extension DOMPageAgent {
    func testSetCachedDocumentScopeID(_ documentScopeID: DOMDocumentScopeID) {
        self.documentScopeID = documentScopeID
    }

    var testCachedPageEpoch: Int {
        pageEpoch
    }

    var testCachedDocumentScopeID: DOMDocumentScopeID {
        documentScopeID
    }

    func testInstallCompletedPreparedPageContextSyncTask(generation: UInt64) {
        pageEpochApplyGeneration = generation
        pageEpochSyncTaskGeneration = generation
        pageEpochSyncTask = Task.detached {}
    }

    func testSetDocumentScopeSyncRetryLimitOverride(_ limit: Int?) {
        testDocumentScopeSyncRetryLimitOverride = limit
    }

    func testAdvancePageEpochApplyGenerationWithoutClearingTask() {
        pageEpochApplyGeneration += 1
    }

    var testHasPreparedPageContextSyncTask: Bool {
        pageEpochSyncTask != nil
    }
}
#endif

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
private let domAgentBootstrapWindowKey = "__wiDOMAgentBootstrap"
private let domAgentBootstrapScriptMarker = "__wiDOMAgentBootstrapUserScript"
private typealias DOMBridgeScriptInstaller = @MainActor (WKWebView, String, WKContentWorld) async throws -> Void

private struct DOMBootstrapConfiguration {
    let pageEpoch: Int
    let documentScopeID: DOMDocumentScopeID
    let autoSnapshotEnabled: Bool
    let autoSnapshotMaxDepth: Int
    let autoSnapshotDebounce: Int

    var signature: String {
        "\(pageEpoch)|\(documentScopeID)|\(autoSnapshotEnabled ? 1 : 0)|\(autoSnapshotMaxDepth)|\(autoSnapshotDebounce)"
    }

    var autoSnapshotOptions: NSDictionary {
        [
            "maxDepth": NSNumber(value: autoSnapshotMaxDepth),
            "debounce": NSNumber(value: autoSnapshotDebounce),
            "enabled": NSNumber(value: autoSnapshotEnabled),
        ]
    }

    var scriptSource: String {
        let enabledLiteral = autoSnapshotEnabled ? "true" : "false"
        return """
        (function() {
            /* \(domAgentBootstrapScriptMarker) */
            const bootstrap = {
                pageEpoch: \(pageEpoch),
                documentScopeID: \(documentScopeID),
                autoSnapshot: {
                    enabled: \(enabledLiteral),
                    maxDepth: \(autoSnapshotMaxDepth),
                    debounce: \(autoSnapshotDebounce)
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
public final class DOMPageAgent: NSObject, PageAgent {
    public struct SelectionModeResult: Decodable, Sendable {
        public struct SelectedAttribute: Decodable, Sendable {
            public let name: String
            public let value: String
        }

        public let cancelled: Bool
        public let requiredDepth: Int
        public let selectedPath: [Int]?
        public let selectedLocalId: UInt64?
        public let ancestorLocalIds: [UInt64]?
        public let selectedBackendNodeId: UInt64?
        public let selectedBackendNodeIdIsStable: Bool?
        public let ancestorBackendNodeIds: [UInt64]?
        public let selectedAttributes: [SelectedAttribute]?
        public let selectedPreview: String?
        public let selectedSelectorPath: String?
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
    private var documentURL: String?
    private var autoSnapshotEnabled = false

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
    private var pageNavigationObservations: [NSKeyValueObservation] = []
    private var navigationRefreshTask: Task<Void, Never>?
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
    package var testPageContextFromPageOverride: (@MainActor (WKWebView) async -> DOMPageContext?)?
    package var testApplyDocumentScopeIDOverride: (@MainActor (DOMDocumentScopeID, WKWebView) async -> Bool)?
#endif

    package var currentBridgeMode: WIBridgeMode {
        bridgeMode
    }

    package var currentPageContext: DOMPageContext {
        .init(pageEpoch: pageEpoch, documentScopeID: documentScopeID, documentURL: documentURL)
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
        guard let handlerName = HandlerName(rawValue: message.name) else {
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
        let payloadKind = if let dictionary = bundle as? NSDictionary {
            dictionary["kind"] as? String ?? "unknown"
        } else if let dictionary = bundle as? [String: Any] {
            dictionary["kind"] as? String ?? "unknown"
        } else {
            "raw"
        }

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
        let rawResult = try await webView.callAsyncJavaScriptCompat(
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

    package func setPendingSelectionPath(_ path: [Int]?) async {
        guard let webView else {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.setPendingSelectionPath(path)",
            arguments: ["path": path as Any],
            contentWorld: bridgeWorld
        )
    }

    package func highlight(nodeId: Int, reveal: Bool = true) async {
        guard let webView else {
            return
        }
        if await runHandleCommand(
            .highlight,
            nodeId: nodeId,
            on: webView,
            expectedPageEpoch: pageEpoch,
            reveal: reveal
        ) {
            return
        }
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.highlightNode(identifier, expectedPageEpoch, reveal)",
            arguments: [
                "identifier": nodeId,
                "expectedPageEpoch": pageEpoch,
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
            "window.webInspectorDOM && window.webInspectorDOM.clearHighlight(expectedPageEpoch);",
            arguments: ["expectedPageEpoch": pageEpoch],
            contentWorld: bridgeWorld
        )
    }
}

// MARK: - DOM Snapshot

package enum DOMSnapshotInitialModeOwnership: Sendable {
    case preservePendingInitialMode
    case consumePendingInitialMode
}

extension DOMPageAgent {
    package func captureSnapshot(
        maxDepth: Int,
        initialModeOwnership: DOMSnapshotInitialModeOwnership = .preservePendingInitialMode
    ) async throws -> String {
        let payload = try await snapshotPayload(
            maxDepth: maxDepth,
            preferEnvelope: false,
            initialModeOwnership: initialModeOwnership
        )
        return try jsonString(from: payload)
    }

    package func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        let payload = try await subtreePayload(
            target: .local(UInt64(nodeId)),
            maxDepth: maxDepth,
            preferEnvelope: false
        )
        let json = try jsonString(from: payload)
        guard !json.isEmpty else {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        return json
    }

    package func captureSnapshotEnvelope(
        maxDepth: Int,
        initialModeOwnership: DOMSnapshotInitialModeOwnership = .preservePendingInitialMode
    ) async throws -> Any {
        try await snapshotPayload(
            maxDepth: maxDepth,
            preferEnvelope: bridgeMode != .legacyJSON,
            initialModeOwnership: initialModeOwnership
        )
    }

    package func captureSubtreeEnvelope(target: DOMRequestNodeTarget, maxDepth: Int) async throws -> Any {
        try await subtreePayload(target: target, maxDepth: maxDepth, preferEnvelope: bridgeMode != .legacyJSON)
    }
}

// MARK: - DOM Mutations

extension DOMPageAgent {
    package func removeNode(
        target: DOMRequestNodeTarget,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        guard let webView else {
            return .failed
        }
        guard let targetArgument = javascriptTargetArgument(for: target) else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawResult = try await webView.callAsyncJavaScriptCompat(
                "return window.webInspectorDOM.removeNode(target, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "target": targetArgument,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            let result = parseMutationExecutionResult(rawResult as Any)
            if case .applied = result {
                handleCache.clear()
            }
            return result
        } catch {
            domLogger.error("remove node failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    package func removeNodeWithUndo(
        target: DOMRequestNodeTarget,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Int> {
        guard let webView else {
            return .failed
        }
        guard let identifier = javascriptRemovalTargetArgument(for: target) else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawValue = try await webView.callAsyncJavaScriptCompat(
                "return window.webInspectorDOM.removeNodeWithUndo(identifier, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "identifier": identifier,
                    "expectedPageEpoch": expectedPageEpoch as Any,
                    "expectedDocumentScopeID": expectedDocumentScopeID as Any,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
            let result = parseUndoMutationExecutionResult(rawValue as Any)
            if case .applied = result {
                handleCache.clear()
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
            let rawValue = try await webView.callAsyncJavaScriptCompat(
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
            let rawValue = try await webView.callAsyncJavaScriptCompat(
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
        target: DOMRequestNodeTarget,
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
            guard let targetArgument = self.javascriptTargetArgument(for: target) else {
                return .failed
            }
            do {
                let rawValue = try await webView.callAsyncJavaScriptCompat(
                    "return window.webInspectorDOM.setAttributeForNode(target, name, value, expectedPageEpoch, expectedDocumentScopeID)",
                    arguments: [
                        "target": targetArgument,
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
                target.jsIdentifier ?? -1,
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
        target: DOMRequestNodeTarget,
        name: String,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: DOMDocumentScopeID? = nil
    ) async -> DOMMutationExecutionResult<Void> {
        guard let webView else {
            return .failed
        }
        guard let targetArgument = javascriptTargetArgument(for: target) else {
            return .failed
        }
        await waitForPreparedPageContextSyncIfNeeded()
        do {
            let rawValue = try await webView.callAsyncJavaScriptCompat(
                "return window.webInspectorDOM.removeAttributeForNode(target, name, expectedPageEpoch, expectedDocumentScopeID)",
                arguments: [
                    "target": targetArgument,
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

    package func selectionCopyText(target: DOMRequestNodeTarget, kind: DOMSelectionCopyKind) async throws -> String {
        return try await evaluateStringScript(
            """
            return window.webInspectorDOM?.\(kind.jsFunction)(target) ?? ""
            """,
            target: target
        )
    }

    package func consumePendingInitialSnapshotMode(
        expectedPageEpoch: Int,
        expectedDocumentScopeID: DOMDocumentScopeID
    ) async {
        await consumePendingInitialSnapshotModeImpl(
            expectedPageEpoch: expectedPageEpoch,
            expectedDocumentScopeID: expectedDocumentScopeID
        )
    }
}

// MARK: - Auto Snapshot

extension DOMPageAgent {
    package func setAutoSnapshot(enabled: Bool) async {
        autoSnapshotEnabled = enabled
        let bootstrap = currentBootstrapConfiguration()
        let options = bootstrap.autoSnapshotOptions
        guard let webView else {
            return
        }
        await refreshDOMBootstrapIfNeeded(on: webView)
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
    package func preparePageEpoch(_ pageEpoch: Int) {
        guard pageEpoch != self.pageEpoch else {
            return
        }
        handleCache.clear()
        self.pageEpoch = pageEpoch
        scheduleBootstrapRefreshIfAttached()
    }

    package func prepareDocumentScopeID(_ documentScopeID: DOMDocumentScopeID) {
        guard documentScopeID != self.documentScopeID else {
            return
        }
        handleCache.clear()
        self.documentScopeID = documentScopeID
        scheduleBootstrapRefreshIfAttached()
    }

    package func cancelPreparedPageContextSync() {
        _ = beginPageEpochApplyGeneration()
    }

    package func readPageContext(on webView: WKWebView) async -> DOMPageContext? {
        await pageContextFromPageIfPossible(on: webView)
    }

    package func commitPageContext(_ pageContext: DOMPageContext, on webView: WKWebView) {
        guard self.webView === webView else {
            return
        }
        let incomingDocumentURL = normalizedDocumentURL(pageContext.documentURL)
        let didChangeDocument = incomingDocumentURL != documentURL
        if didChangeDocument || pageContext.pageEpoch != self.pageEpoch || pageContext.documentScopeID != self.documentScopeID {
            handleCache.clear()
            self.pageEpoch = pageContext.pageEpoch
            self.documentScopeID = pageContext.documentScopeID
        }
        documentURL = incomingDocumentURL
    }

    package func refreshCurrentPageContextIfPossible(on webView: WKWebView) async -> Bool {
        await refreshCachedPageContextFromPageIfPossible(on: webView)
    }

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
            if self.documentScopeID == documentScopeID {
                let observedPageContext = await pageContextFromPageIfPossible(on: webView)
                guard self.webView === webView else {
                    return false
                }
                if let expectedPageEpoch, self.pageEpoch != expectedPageEpoch {
                    return false
                }
                if let observedPageContext {
                    commitPageContext(observedPageContext, on: webView)
                    if observedPageContext.documentScopeID == documentScopeID {
                        return true
                    }
                    let didProgress = observedPageContext.documentScopeID != lastObservedDocumentScopeID
                    if didProgress {
                        lastObservedDocumentScopeID = observedPageContext.documentScopeID
                    }
                } else {
                    if !consumeRetry(progressedForward: false) {
                        return false
                    }
                    try? await Task.sleep(nanoseconds: pageEpochApplyRetryDelayNanoseconds)
                }
            }
            let didApply = await applyDocumentScopeID(documentScopeID, on: webView)
            if didApply {
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
                if self.documentScopeID == documentScopeID {
                    return true
                }
                let didProgress = self.documentScopeID != lastObservedDocumentScopeID
                if didProgress {
                    lastObservedDocumentScopeID = self.documentScopeID
                }
                if !consumeRetry(progressedForward: didProgress) {
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
        await refreshDOMBootstrapIfNeeded(on: webView)
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
            } else {
                await refreshDOMBootstrapIfNeeded(on: webView)
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
        navigationRefreshTask?.cancel()
        navigationRefreshTask = nil
        pageNavigationObservations.removeAll()
        detachMessageHandlers(from: webView)
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        resolveBridgeModeIfNeeded(with: webView)
        registerMessageHandlers(on: webView)
        observePageNavigationState(on: webView)
    }

    func didClearPageWebView() {
        _ = beginPageEpochApplyGeneration()
        navigationRefreshTask?.cancel()
        navigationRefreshTask = nil
        pageNavigationObservations.removeAll()
        handleCache.clear()
        documentURL = nil
    }
}

// MARK: - Private helpers

private extension DOMPageAgent {
    func observePageNavigationState(on webView: WKWebView) {
        pageNavigationObservations.removeAll()
        let urlObservation = webView.observe(\.url, options: [.new]) { [weak self, weak webView] observedWebView, _ in
            guard let self, let webView, self.webView === webView else {
                return
            }
            guard !observedWebView.isLoading else {
                return
            }
            guard self.shouldScheduleNavigationRefresh(for: observedWebView.url) else {
                return
            }
            self.scheduleNavigationRefreshIfNeeded(on: webView)
        }
        let loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] observedWebView, _ in
            guard let self, let webView else {
                return
            }
            guard observedWebView.isLoading == false else {
                return
            }
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, self.webView === webView else {
                    return
                }
                if self.shouldScheduleNavigationRefresh(for: observedWebView.url) {
                    self.scheduleNavigationRefreshIfNeeded(on: webView)
                    return
                }
                guard let pageContext = await self.readPageContext(on: webView) else {
                    return
                }
                let normalizedCurrentDocumentURL = self.documentURL.map(self.navigationComparableURLString)
                let normalizedObservedDocumentURL = pageContext.documentURL.map(self.navigationComparableURLString)
                if pageContext.pageEpoch != self.pageEpoch
                    || pageContext.documentScopeID != self.documentScopeID
                    || normalizedObservedDocumentURL != normalizedCurrentDocumentURL
                {
                    self.scheduleNavigationRefreshIfNeeded(on: webView, force: true)
                }
            }
        }
        pageNavigationObservations = [urlObservation, loadingObservation]
    }

    func shouldScheduleNavigationRefresh(for url: URL?) -> Bool {
        guard let currentURLString = url?.absoluteString, !currentURLString.isEmpty else {
            return false
        }
        guard let documentURL else {
            return false
        }
        return navigationComparableURLString(currentURLString) != navigationComparableURLString(documentURL)
    }

    func navigationComparableURLString(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value
        }
        components.fragment = nil
        return components.string ?? value
    }

    func scheduleNavigationRefreshIfNeeded(on webView: WKWebView, force: Bool = false) {
        guard self.webView === webView else {
            return
        }
        navigationRefreshTask?.cancel()
        navigationRefreshTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else {
                return
            }
            do {
                try await Task.sleep(nanoseconds: pageEpochApplyRetryDelayNanoseconds)
            } catch {
                return
            }
            guard self.webView === webView else {
                return
            }
            guard force || self.shouldScheduleNavigationRefresh(for: webView.url) else {
                return
            }
            await self.ensureDOMAgentScriptInstalled(on: webView)
            guard self.autoSnapshotEnabled else {
                return
            }
            await self.setAutoSnapshot(enabled: true)
            guard self.autoSnapshotEnabled else {
                return
            }
            await self.triggerInitialSnapshotUpdate(on: webView)
        }
    }

    func triggerInitialSnapshotUpdate(on webView: WKWebView) async {
        guard self.webView === webView else {
            return
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOM?.triggerSnapshotUpdate?.('initial')",
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("trigger initial snapshot skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func scheduleBootstrapRefreshIfAttached() {
        guard let webView else {
            return
        }
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else {
                return
            }
            await refreshDOMBootstrapIfNeeded(on: webView)
        }
    }

    func currentBootstrapConfiguration() -> DOMBootstrapConfiguration {
        return DOMBootstrapConfiguration(
            pageEpoch: pageEpoch,
            documentScopeID: documentScopeID,
            autoSnapshotEnabled: autoSnapshotEnabled,
            autoSnapshotMaxDepth: max(1, configuration.snapshotDepth),
            autoSnapshotDebounce: max(50, Int(configuration.autoUpdateDebounce * 1000))
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
        var didReplaceExistingBootstrap = false
        let updatedScripts = controller.userScripts.compactMap { script in
            guard script.source.contains(domAgentBootstrapScriptMarker) else {
                return script
            }
            guard !didReplaceExistingBootstrap else {
                return nil
            }
            didReplaceExistingBootstrap = true
            return bootstrapScript
        }

        controller.removeAllUserScripts()
        if didReplaceExistingBootstrap {
            updatedScripts.forEach { controller.addUserScript($0) }
        } else {
            controller.addUserScript(bootstrapScript)
            updatedScripts.forEach { controller.addUserScript($0) }
        }
    }

    func refreshDOMBootstrapIfNeeded(on webView: WKWebView) async {
        guard self.webView === webView else {
            return
        }
        let controller = webView.configuration.userContentController
        let bootstrap = currentBootstrapConfiguration()
        let didAppendUserScript = controllerStateRegistry.domBootstrapSignature(on: controller) != bootstrap.signature
        if didAppendUserScript {
            replaceBootstrapUserScript(on: controller, with: makeBootstrapUserScript(bootstrap))
            controllerStateRegistry.setDOMBootstrapSignature(bootstrap.signature, on: controller)
        }

        do {
            try await webView.callAsyncVoidJavaScript(
                bootstrap.scriptSource,
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("refresh DOM bootstrap skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

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
        guard let pageContext = await pageContextFromPageIfPossible(on: webView) else {
            return false
        }
        commitPageContext(pageContext, on: webView)
        return true
    }

    func pageContextFromPageIfPossible(on webView: WKWebView) async -> DOMPageContext? {
        guard self.webView === webView else {
            return nil
        }
#if DEBUG
        if let testPageContextFromPageOverride {
            return await testPageContextFromPageOverride(webView)
        }
#endif
        do {
            let rawResult = try await webView.callAsyncJavaScriptCompat(
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
                        documentURL: typeof status.documentURL === "string" ? status.documentURL : null,
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
            let appliedDocumentURL = appliedContext?["documentURL"] as? String
            let appliedEpoch = (appliedContext?["pageEpoch"] as? Int) ?? (appliedContext?["pageEpoch"] as? NSNumber)?.intValue
            let appliedDocumentScopeID = (appliedContext?["documentScopeID"] as? UInt64) ?? (appliedContext?["documentScopeID"] as? NSNumber)?.uint64Value
            guard appliedEpoch != nil || appliedDocumentScopeID != nil || normalizedDocumentURL(appliedDocumentURL) != nil else {
                return nil
            }
            return .init(
                pageEpoch: appliedEpoch ?? pageEpoch,
                documentScopeID: appliedDocumentScopeID ?? documentScopeID,
                documentURL: appliedDocumentURL
            )
        } catch {
            domLogger.debug("refresh cached page context skipped: \(error.localizedDescription, privacy: .public)")
            return nil
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
#if DEBUG
        if let testApplyDocumentScopeIDOverride {
            return await testApplyDocumentScopeIDOverride(documentScopeID, webView)
        }
#endif
        do {
            let rawResult = try await webView.callAsyncJavaScriptCompat(
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
            await refreshDOMBootstrapIfNeeded(on: webView)
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
            let rawResult = try await webView.callAsyncJavaScriptCompat(
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
            let pageEpochMatches = epoch == nil || appliedEpoch == epoch
            let documentScopeMatches = documentScopeID == nil || appliedDocumentScopeID == documentScopeID
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
            await refreshDOMBootstrapIfNeeded(on: webView)
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
        webView.evaluateJavaScriptCompat(
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
            let rawResult = try await webView.callAsyncJavaScriptCompat(
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
        let bootstrap = currentBootstrapConfiguration()

        if controllerStateRegistry.domBridgeScriptInstalled(on: controller) {
            await refreshDOMBootstrapIfNeeded(on: webView)
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
            makeBootstrapUserScript(bootstrap)
        )
        controllerStateRegistry.setDOMBootstrapSignature(bootstrap.signature, on: controller)
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
            try await webView.callAsyncVoidJavaScript(
                bootstrap.scriptSource,
                contentWorld: bridgeWorld
            )
            try await installDOMBridgeScript(webView, scriptSource, bridgeWorld)
        } catch {
            domLogger.error(
                "failed to evaluate DOM agent script after registration: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func evaluateStringScript(_ script: String, target: DOMRequestNodeTarget) async throws -> String {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        guard let targetArgument = javascriptTargetArgument(for: target) else {
            return ""
        }
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            script,
            arguments: ["target": targetArgument],
            in: nil,
            contentWorld: bridgeWorld
        )
        return rawResult as? String ?? ""
    }

    private func javascriptTargetArgument(for target: DOMRequestNodeTarget) -> Any? {
        target.jsArgument
    }

    private func javascriptRemovalTargetArgument(for target: DOMRequestNodeTarget) -> Any? {
        javascriptTargetArgument(for: target)
    }

    func snapshotPayload(
        maxDepth: Int,
        preferEnvelope: Bool,
        initialModeOwnership: DOMSnapshotInitialModeOwnership
    ) async throws -> Any {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let captureExpression: String
        let captureEnvelopeExpression: String
        switch initialModeOwnership {
        case .preservePendingInitialMode:
            captureExpression = "window.webInspectorDOM.captureSnapshot(maxDepth, { consumeInitialSnapshotMode: false })"
            captureEnvelopeExpression = "window.webInspectorDOM.captureSnapshotEnvelope(maxDepth, { consumeInitialSnapshotMode: false })"
        case .consumePendingInitialMode:
            captureExpression = "window.webInspectorDOM.captureSnapshot(maxDepth)"
            captureEnvelopeExpression = "window.webInspectorDOM.captureSnapshotEnvelope(maxDepth)"
        }
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            preferEnvelope
                ? """
                if (window.webInspectorDOM && typeof window.webInspectorDOM.captureSnapshotEnvelope === "function") {
                    return \(captureEnvelopeExpression);
                }
                return \(captureExpression);
                """
                : "return \(captureExpression)",
            arguments: ["maxDepth": max(1, maxDepth)],
            in: nil,
            contentWorld: bridgeWorld
        )
        return unwrapOptionalPayload(rawResult) as Any
    }

    func consumePendingInitialSnapshotModeImpl(
        expectedPageEpoch: Int,
        expectedDocumentScopeID: DOMDocumentScopeID
    ) async {
        guard let webView else {
            return
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                """
                if (window.webInspectorDOM && typeof window.webInspectorDOM.consumePendingInitialSnapshotMode === "function") {
                    window.webInspectorDOM.consumePendingInitialSnapshotMode(expectedPageEpoch, expectedDocumentScopeID);
                }
                """,
                arguments: [
                    "expectedPageEpoch": expectedPageEpoch,
                    "expectedDocumentScopeID": expectedDocumentScopeID,
                ],
                in: nil,
                contentWorld: bridgeWorld
            )
        } catch {
            domLogger.debug("consume pending initial snapshot mode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func subtreePayload(target: DOMRequestNodeTarget, maxDepth: Int, preferEnvelope: Bool) async throws -> Any {
        guard let webView else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        guard let targetArgument = javascriptTargetArgument(for: target) else {
            throw WebInspectorCoreError.subtreeUnavailable
        }
        let rawResult = try await webView.callAsyncJavaScriptCompat(
            preferEnvelope
                ? """
                if (window.webInspectorDOM && typeof window.webInspectorDOM.captureSubtreeEnvelope === "function") {
                    return window.webInspectorDOM.captureSubtreeEnvelope(target, maxDepth);
                }
                return window.webInspectorDOM.captureSubtree(target, maxDepth);
                """
                : "return window.webInspectorDOM.captureSubtree(target, maxDepth)",
            arguments: [
                "target": targetArgument,
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
        expectedPageEpoch: Int? = nil,
        reveal: Bool = true
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
                expectedPageEpoch: expectedPageEpoch,
                reveal: reveal
            )
            let rawResult = try await webView.callAsyncJavaScriptCompat(
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
            let rawResult = try await webView.callAsyncJavaScriptCompat(
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
        expectedPageEpoch: Int?,
        reveal: Bool
    ) -> (script: String, arguments: [String: Any]) {
        var arguments: [String: Any] = [
            "handle": handle,
            "unavailable": unavailableBridgeSentinel,
            "reveal": reveal,
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
            return window.webInspectorDOM.highlightNodeHandle(handle, expectedPageEpoch, reveal);
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

#if DEBUG
extension DOMPageAgent {
    func testJavaScriptRemovalTargetArgument(for target: DOMRequestNodeTarget) -> Any? {
        javascriptRemovalTargetArgument(for: target)
    }

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

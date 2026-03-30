import WebKit

@MainActor
package final class DOMSession {
    package typealias AttachmentResult = (shouldReload: Bool, shouldPreserveInspectorState: Bool)

    package private(set) var configuration: DOMConfiguration

    package private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: DOMPageAgent
    private var autoSnapshotEnabled = false
    private var preparedPageEpoch = 0
    private var preparedDocumentScopeID: DOMDocumentScopeID = 0

    var isAutoSnapshotEnabled: Bool {
        autoSnapshotEnabled
    }

    package var bridgeMode: WIBridgeMode {
        pageAgent.currentBridgeMode
    }

    package weak var bundleSink: (any DOMBundleSink)? {
        didSet {
            pageAgent.sink = bundleSink
        }
    }

    package init(configuration: DOMConfiguration = .init()) {
        self.configuration = configuration
        pageAgent = DOMPageAgent(configuration: configuration)
    }

    package func updateConfiguration(_ configuration: DOMConfiguration) async {
        self.configuration = configuration
        pageAgent.updateConfiguration(configuration)
        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }
    }

    package var pageWebView: WKWebView? {
        pageAgent.webView
    }

    package var hasPageWebView: Bool {
        pageAgent.webView != nil
    }

    @discardableResult
    package func attach(to webView: WKWebView) async -> AttachmentResult {
        if pageAgent.webView === webView {
            lastPageWebView = webView
            return (false, false)
        }

        if let attachedWebView = pageAgent.webView, attachedWebView !== webView {
            await pageAgent.detachPageWebViewAndWaitForCleanup()
        }

        let previousWebView = lastPageWebView
        let shouldPreserveState = pageAgent.webView == nil && previousWebView === webView
        let shouldReload = shouldPreserveState || previousWebView !== webView
        pageAgent.attachPageWebView(webView)
        await pageAgent.ensureDOMAgentScriptInstalled(
            on: webView,
            pageEpoch: preparedPageEpoch,
            documentScopeID: preparedDocumentScopeID
        )
        lastPageWebView = webView

        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }

        return (shouldReload, shouldPreserveState)
    }

    package func suspend() async {
        await pageAgent.detachPageWebViewAndWaitForCleanup()
    }

    package func detach() async {
        await suspend()
        lastPageWebView = nil
    }

    package func reloadPage() {
        pageAgent.reloadPage()
    }

    package func reloadPageAndWaitForPreparedPageEpochSync() async {
        await pageAgent.reloadPageAndWaitForPreparedPageEpochSync(
            preparedPageEpoch,
            documentScopeID: preparedDocumentScopeID
        )
        if autoSnapshotEnabled, pageAgent.webView != nil {
            await pageAgent.setAutoSnapshot(enabled: true)
        }
    }

    package func setAutoSnapshot(enabled: Bool) async {
        autoSnapshotEnabled = enabled
        guard pageAgent.webView != nil else {
            return
        }
        await pageAgent.setAutoSnapshot(enabled: enabled)
    }

    package func preparePageEpoch(_ epoch: Int) {
        preparedPageEpoch = epoch
    }

    package func prepareDocumentScopeID(_ scopeID: DOMDocumentScopeID) {
        preparedDocumentScopeID = scopeID
    }

    package func syncCurrentDocumentScopeIDIfNeeded(_ scopeID: DOMDocumentScopeID) async {
        preparedDocumentScopeID = scopeID
        guard let webView = pageAgent.webView else {
            return
        }
        await pageAgent.ensureDOMAgentScriptInstalled(
            on: webView,
            pageEpoch: nil,
            documentScopeID: scopeID
        )
    }

    package func tearDownForDeinit() {
        pageAgent.tearDownForDeinit()
        lastPageWebView = nil
        autoSnapshotEnabled = false
    }
}

// MARK: - Snapshot API (for DOMTreeView)

extension DOMSession {
    package func captureSnapshot(maxDepth: Int) async throws -> String {
        try await pageAgent.captureSnapshot(maxDepth: maxDepth)
    }

    package func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        try await pageAgent.captureSubtree(nodeId: nodeId, maxDepth: maxDepth)
    }

    package func matchedStyles(nodeId: Int, maxRules: Int = 0) async throws -> DOMMatchedStylesPayload {
        try await pageAgent.matchedStyles(nodeId: nodeId, maxRules: maxRules)
    }
}

// MARK: - Snapshot API (bridge/object)

extension DOMSession {
    package func captureSnapshotPayload(maxDepth: Int) async throws -> Any {
        try await pageAgent.captureSnapshotEnvelope(maxDepth: maxDepth)
    }

    package func captureSubtreePayload(nodeId: Int, maxDepth: Int) async throws -> Any {
        try await pageAgent.captureSubtreeEnvelope(nodeId: nodeId, maxDepth: maxDepth)
    }
}

// MARK: - Selection / Highlight

extension DOMSession {
    package func beginSelectionMode() async throws -> DOMPageAgent.SelectionModeResult {
        try await pageAgent.beginSelectionMode()
    }

    package func cancelSelectionMode() async {
        await pageAgent.cancelSelectionMode()
    }

    package func highlight(nodeId: Int) async {
        await pageAgent.highlight(nodeId: nodeId)
    }

    package func hideHighlight() async {
        await pageAgent.hideHighlight()
    }
}

// MARK: - DOM Mutations

extension DOMSession {
    package func removeNode(nodeId: Int) async {
        await pageAgent.removeNode(nodeId: nodeId)
    }

    package func removeNodeWithUndo(nodeId: Int) async -> Int? {
        await pageAgent.removeNodeWithUndo(nodeId: nodeId)
    }

    package func undoRemoveNode(undoToken: Int) async -> Bool {
        await pageAgent.undoRemoveNode(undoToken: undoToken)
    }

    package func redoRemoveNode(undoToken: Int, nodeId: Int? = nil) async -> Bool {
        await pageAgent.redoRemoveNode(undoToken: undoToken, nodeId: nodeId)
    }

    package func setAttribute(nodeId: Int, name: String, value: String) async {
        await pageAgent.setAttribute(nodeId: nodeId, name: name, value: value)
    }

    package func removeAttribute(nodeId: Int, name: String) async {
        await pageAgent.removeAttribute(nodeId: nodeId, name: name)
    }
}

// MARK: - Copy Helpers

extension DOMSession {
    package func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await pageAgent.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    package func selectorPath(nodeId: Int) async throws -> String {
        try await selectionCopyText(nodeId: nodeId, kind: .selectorPath)
    }
}

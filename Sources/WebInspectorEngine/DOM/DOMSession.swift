import WebKit

@MainActor
public final class DOMSession {
    public typealias AttachmentResult = (shouldReload: Bool, preserveState: Bool)

    public private(set) var configuration: DOMConfiguration
    public let graphStore: DOMGraphStore

    public private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: DOMPageAgent
    private var autoSnapshotEnabled = false

    var isAutoSnapshotEnabled: Bool {
        autoSnapshotEnabled
    }

    package var bridgeMode: WIBridgeMode {
        pageAgent.currentBridgeMode
    }

    public weak var bundleSink: (any DOMBundleSink)? {
        didSet {
            pageAgent.sink = bundleSink
        }
    }

    public init(configuration: DOMConfiguration = .init()) {
        self.configuration = configuration
        graphStore = DOMGraphStore()
        pageAgent = DOMPageAgent(configuration: configuration)
    }

    public func updateConfiguration(_ configuration: DOMConfiguration) async {
        self.configuration = configuration
        pageAgent.updateConfiguration(configuration)
        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }
    }

    public var pageWebView: WKWebView? {
        pageAgent.webView
    }

    public var hasPageWebView: Bool {
        pageAgent.webView != nil
    }

    @discardableResult
    public func attach(to webView: WKWebView) async -> AttachmentResult {
        if pageAgent.webView === webView {
            lastPageWebView = webView
            return (false, false)
        }

        if let attachedWebView = pageAgent.webView, attachedWebView !== webView {
            await pageAgent.detachPageWebViewAndWaitForCleanup()
        }

        graphStore.resetForDocumentUpdate()

        let previousWebView = lastPageWebView
        let shouldPreserveState = pageAgent.webView == nil && previousWebView === webView
        let shouldReload = shouldPreserveState || previousWebView !== webView
        pageAgent.attachPageWebView(webView)
        await pageAgent.ensureDOMAgentScriptInstalled(on: webView)
        lastPageWebView = webView

        if autoSnapshotEnabled {
            await pageAgent.setAutoSnapshot(enabled: true)
        }

        return (shouldReload, shouldPreserveState)
    }

    public func suspend() async {
        await pageAgent.detachPageWebViewAndWaitForCleanup()
    }

    public func detach() async {
        await suspend()
        graphStore.resetForDocumentUpdate()
        lastPageWebView = nil
    }

    public func reloadPage() {
        pageAgent.webView?.reload()
    }

    public func setAutoSnapshot(enabled: Bool) async {
        autoSnapshotEnabled = enabled
        guard pageAgent.webView != nil else {
            return
        }
        await pageAgent.setAutoSnapshot(enabled: enabled)
    }

    package func tearDownForDeinit() {
        pageAgent.tearDownForDeinit()
        graphStore.resetForDocumentUpdate()
        lastPageWebView = nil
        autoSnapshotEnabled = false
    }
}

// MARK: - Snapshot API (for DOMTreeView)

public extension DOMSession {
    func captureSnapshot(maxDepth: Int) async throws -> String {
        try await pageAgent.captureSnapshot(maxDepth: maxDepth)
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        try await pageAgent.captureSubtree(nodeId: nodeId, maxDepth: maxDepth)
    }

    func matchedStyles(nodeId: Int, maxRules: Int = 0) async throws -> DOMMatchedStylesPayload {
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

public extension DOMSession {
    func beginSelectionMode() async throws -> DOMPageAgent.SelectionModeResult {
        try await pageAgent.beginSelectionMode()
    }

    func cancelSelectionMode() async {
        await pageAgent.cancelSelectionMode()
    }

    func highlight(nodeId: Int) async {
        await pageAgent.highlight(nodeId: nodeId)
    }

    func hideHighlight() async {
        await pageAgent.hideHighlight()
    }
}

// MARK: - DOM Mutations

public extension DOMSession {
    func removeNode(nodeId: Int) async {
        await pageAgent.removeNode(nodeId: nodeId)
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        await pageAgent.removeNodeWithUndo(nodeId: nodeId)
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        await pageAgent.undoRemoveNode(undoToken: undoToken)
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int? = nil) async -> Bool {
        await pageAgent.redoRemoveNode(undoToken: undoToken, nodeId: nodeId)
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        await pageAgent.setAttribute(nodeId: nodeId, name: name, value: value)
    }

    func removeAttribute(nodeId: Int, name: String) async {
        await pageAgent.removeAttribute(nodeId: nodeId, name: name)
    }
}

// MARK: - Copy Helpers

public extension DOMSession {
    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await pageAgent.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    func selectorPath(nodeId: Int) async throws -> String {
        try await selectionCopyText(nodeId: nodeId, kind: .selectorPath)
    }
}

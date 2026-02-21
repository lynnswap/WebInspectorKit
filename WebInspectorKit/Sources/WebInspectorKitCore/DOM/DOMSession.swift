import WebKit

@MainActor
public final class DOMSession {
    public typealias AttachmentResult = (shouldReload: Bool, preserveState: Bool)

    public private(set) var configuration: DOMConfiguration
    public let selection: DOMSelection

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
        selection = DOMSelection()
        pageAgent = DOMPageAgent(configuration: configuration)
    }

    public func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
        pageAgent.updateConfiguration(configuration)
        if autoSnapshotEnabled {
            Task {
                await pageAgent.setAutoSnapshot(enabled: true)
            }
        }
    }

    public var pageWebView: WKWebView? {
        pageAgent.webView
    }

    public var hasPageWebView: Bool {
        pageAgent.webView != nil
    }

    @discardableResult
    public func attach(to webView: WKWebView) -> AttachmentResult {
        if pageAgent.webView === webView {
            lastPageWebView = webView
            return (false, false)
        }

        selection.clear()

        let previousWebView = lastPageWebView
        let shouldPreserveState = pageAgent.webView == nil && previousWebView === webView
        let shouldReload = shouldPreserveState || previousWebView !== webView
        pageAgent.attachPageWebView(webView)
        lastPageWebView = webView

        if autoSnapshotEnabled {
            Task {
                await self.pageAgent.setAutoSnapshot(enabled: true)
            }
        }

        return (shouldReload, shouldPreserveState)
    }

    public func suspend() {
        pageAgent.detachPageWebView()
    }

    public func detach() {
        suspend()
        selection.clear()
        lastPageWebView = nil
    }

    public func reloadPage() {
        pageAgent.webView?.reload()
    }

    public func setAutoSnapshot(enabled: Bool) {
        autoSnapshotEnabled = enabled
        guard pageAgent.webView != nil else {
            return
        }
        Task {
            await self.pageAgent.setAutoSnapshot(enabled: enabled)
        }
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

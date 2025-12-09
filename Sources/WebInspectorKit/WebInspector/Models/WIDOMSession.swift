import WebKit

@MainActor
public final class WIDOMSession: WIPageSession {
    public typealias AttachmentResult = (shouldReload: Bool, preserveState: Bool)
    public private(set) var configuration: WebInspectorConfiguration

    let domStore: WIDOMStore
    public var selection: WIDOMSelection {
        domAgent.selection
    }

    public var pageWebView: WKWebView? {
        domAgent.webView
    }

    public var hasPageWebView: Bool {
        domAgent.webView != nil
    }

    public private(set) weak var lastPageWebView: WKWebView?

    private let domAgent: WIDOMPageAgent


    public init(configuration: WebInspectorConfiguration = .init()) {
        self.configuration = configuration
        let domAgent = WIDOMPageAgent(configuration: configuration)
        self.domAgent = domAgent
        let domStore = WIDOMStore(configuration: configuration)
        self.domStore = domStore
        domAgent.inspector = domStore
        domStore.domAgent = domAgent
    }

    public func updateConfiguration(_ configuration: WebInspectorConfiguration) {
        self.configuration = configuration
        domAgent.updateConfiguration(configuration)
        domStore.updateConfiguration(configuration)
    }

    @discardableResult
    public func attach(pageWebView webView: WKWebView) -> AttachmentResult {
        domAgent.selection.clear()

        let previousWebView = lastPageWebView
        let shouldPreserveState = domAgent.webView == nil && previousWebView === webView
        let needsReload = shouldPreserveState || previousWebView !== webView
        domAgent.attachPageWebView(webView)
        lastPageWebView = webView

        return (needsReload, shouldPreserveState)
    }

    public func suspend() {
        domAgent.detachPageWebView()
    }

    public func detach() {
        suspend()
        lastPageWebView = nil
    }

    public func reloadPage() {
        domAgent.webView?.reload()
    }

    func beginSelectionMode() async throws -> WIDOMPageAgent.SelectionResult {
        try await domAgent.beginSelectionMode()
    }

    func cancelSelectionMode() async {
        await domAgent.cancelSelectionMode()
    }

    func clearHighlight() {
        domAgent.clearWebInspectorHighlight()
    }

    func selectionCopyText(for identifier: Int, kind: WISelectionCopyKind) async throws -> String {
        try await domAgent.selectionCopyText(for: identifier, kind: kind)
    }

    func removeNode(identifier: Int) async {
        await domAgent.removeNode(identifier: identifier)
    }

    func updateAttributeValue(identifier: Int, name: String, value: String) async {
        await domAgent.updateAttributeValue(identifier: identifier, name: name, value: value)
    }

    func removeAttribute(identifier: Int, name: String) async {
        await domAgent.removeAttribute(identifier: identifier, name: name)
    }
}

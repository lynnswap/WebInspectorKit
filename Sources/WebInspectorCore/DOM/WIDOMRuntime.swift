import WebKit

@MainActor
package final class WIDOMRuntime {
    package typealias AttachmentResult = (shouldReload: Bool, preserveState: Bool)

    package private(set) var configuration: DOMConfiguration
    package let graphStore: DOMGraphStore

    package private(set) weak var lastPageWebView: WKWebView?
    private let backend: any WIDOMBackend
    private var autoSnapshotEnabled = false

    package weak var eventSink: (any WIDOMProtocolEventSink)? {
        didSet {
            backend.eventSink = eventSink
        }
    }

    package init(
        configuration: DOMConfiguration = .init(),
        graphStore: DOMGraphStore = DOMGraphStore(),
        backend: any WIDOMBackend
    ) {
        self.configuration = configuration
        self.graphStore = graphStore
        self.backend = backend
        self.backend.eventSink = eventSink
    }

    package convenience init(
        configuration: DOMConfiguration = .init(),
        graphStore: DOMGraphStore = DOMGraphStore()
    ) {
        self.init(
            configuration: configuration,
            graphStore: graphStore,
            backend: WIDOMUnavailableBackend()
        )
    }

    package var pageWebView: WKWebView? {
        backend.webView
    }

    package var hasPageWebView: Bool {
        backend.webView != nil
    }

    package var backendSupport: WIInspectorBackendSupport {
        backend.support
    }

    package var transportCapabilities: Set<WIInspectorBackendCapability> {
        backend.support.capabilities
    }

    package var isAutoSnapshotEnabled: Bool {
        autoSnapshotEnabled
    }

    package func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
        backend.updateConfiguration(configuration)
        if autoSnapshotEnabled {
            Task {
                await backend.setAutoSnapshot(enabled: true)
            }
        }
    }

    @discardableResult
    package func attach(to webView: WKWebView) -> AttachmentResult {
        if backend.webView === webView {
            lastPageWebView = webView
            return (false, false)
        }

        graphStore.resetForDocumentUpdate()

        let previousWebView = lastPageWebView
        let shouldPreserveState = backend.webView == nil && previousWebView === webView
        let shouldReload = shouldPreserveState || previousWebView !== webView
        backend.attachPageWebView(webView)
        lastPageWebView = webView

        if autoSnapshotEnabled {
            Task {
                await backend.setAutoSnapshot(enabled: true)
            }
        }

        return (shouldReload, shouldPreserveState)
    }

    package func suspend() {
        backend.detachPageWebView()
    }

    package func detach() {
        suspend()
        graphStore.resetForDocumentUpdate()
        lastPageWebView = nil
    }

    package func reloadPage() {
        backend.webView?.reload()
    }

    package func setAutoSnapshot(enabled: Bool) {
        autoSnapshotEnabled = enabled
        guard backend.webView != nil else {
            return
        }
        Task {
            await backend.setAutoSnapshot(enabled: enabled)
        }
    }

    package func prepareForNavigationReconnect() {
        backend.prepareForNavigationReconnect()
    }

    package func resumeAfterNavigationReconnect(
        to webView: WKWebView,
        reloadDocument: Bool = true
    ) async throws {
        lastPageWebView = webView
        backend.resumeAfterNavigationReconnect()
        guard reloadDocument else {
            return
        }
        try await backend.reloadDocument(preserveState: false, requestedDepth: nil)
    }

    package func captureSnapshot(maxDepth: Int) async throws -> String {
        try await backend.captureSnapshot(maxDepth: maxDepth)
    }

    package func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        try await backend.captureSubtree(nodeId: nodeId, maxDepth: maxDepth)
    }

    package func styles(nodeId: Int, maxMatchedRules: Int = 0) async throws -> DOMNodeStylePayload {
        try await backend.styles(nodeId: nodeId, maxMatchedRules: maxMatchedRules)
    }

    package func reloadDocument(preserveState: Bool = false) async throws {
        try await backend.reloadDocument(preserveState: preserveState, requestedDepth: nil)
    }

    package func reloadDocument(
        preserveState: Bool,
        requestedDepth: Int?
    ) async throws {
        try await backend.reloadDocument(
            preserveState: preserveState,
            requestedDepth: requestedDepth
        )
    }

    package func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        try await backend.requestChildNodes(parentNodeId: parentNodeId)
    }

    package func captureSnapshotPayload(maxDepth: Int) async throws -> Any {
        try await backend.captureSnapshotEnvelope(maxDepth: maxDepth)
    }

    package func captureSubtreePayload(nodeId: Int, maxDepth: Int) async throws -> Any {
        try await backend.captureSubtreeEnvelope(nodeId: nodeId, maxDepth: maxDepth)
    }

    package func beginSelectionMode() async throws -> DOMSelectionModeResult {
        try await backend.beginSelectionMode()
    }

    package func cancelSelectionMode() async {
        await backend.cancelSelectionMode()
    }

    package func highlight(nodeId: Int) async {
        await backend.highlight(nodeId: nodeId)
    }

    package func hideHighlight() async {
        await backend.hideHighlight()
    }

    package func rememberPendingSelection(nodeId: Int?) {
        backend.rememberPendingSelection(nodeId: nodeId)
    }

    package func removeNode(nodeId: Int) async {
        await backend.removeNode(nodeId: nodeId)
    }

    package func removeNodeWithUndo(nodeId: Int) async -> Int? {
        await backend.removeNodeWithUndo(nodeId: nodeId)
    }

    package func undoRemoveNode(undoToken: Int) async -> Bool {
        await backend.undoRemoveNode(undoToken: undoToken)
    }

    package func redoRemoveNode(undoToken: Int, nodeId: Int? = nil) async -> Bool {
        await backend.redoRemoveNode(undoToken: undoToken, nodeId: nodeId)
    }

    package func setAttribute(nodeId: Int, name: String, value: String) async {
        await backend.setAttribute(nodeId: nodeId, name: name, value: value)
    }

    package func removeAttribute(nodeId: Int, name: String) async {
        await backend.removeAttribute(nodeId: nodeId, name: name)
    }

    package func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        try await backend.selectionCopyText(nodeId: nodeId, kind: kind)
    }

    package func selectorPath(nodeId: Int) async throws -> String {
        try await selectionCopyText(nodeId: nodeId, kind: .selectorPath)
    }
}

#if DEBUG
extension WIDOMRuntime {
    package func testBackendTypeName() -> String {
        String(describing: type(of: backend))
    }

    package func testPageAgentTypeName() -> String {
        testBackendTypeName()
    }
}
#endif

@MainActor
private final class WIDOMUnavailableBackend: WIDOMBackend {
    weak var eventSink: (any WIDOMProtocolEventSink)?
    weak var webView: WKWebView?

    let support = WIInspectorBackendSupport(
        availability: .unsupported,
        backendKind: .unsupported,
        failureReason: "No backend was provided."
    )

    func updateConfiguration(_ configuration: DOMConfiguration) {
        _ = configuration
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView() {
        webView = nil
    }

    func setAutoSnapshot(enabled: Bool) async {
        _ = enabled
    }

    func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws {
        _ = preserveState
        _ = requestedDepth
        throw WebInspectorCoreError.scriptUnavailable
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        _ = parentNodeId
        throw WebInspectorCoreError.subtreeUnavailable
    }

    func captureSnapshot(maxDepth: Int) async throws -> String {
        _ = maxDepth
        throw WebInspectorCoreError.scriptUnavailable
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        _ = nodeId
        _ = maxDepth
        throw WebInspectorCoreError.subtreeUnavailable
    }

    func styles(nodeId: Int, maxMatchedRules: Int) async throws -> DOMNodeStylePayload {
        _ = nodeId
        _ = maxMatchedRules
        throw WebInspectorCoreError.scriptUnavailable
    }

    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        _ = maxDepth
        throw WebInspectorCoreError.scriptUnavailable
    }

    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        _ = nodeId
        _ = maxDepth
        throw WebInspectorCoreError.subtreeUnavailable
    }

    func beginSelectionMode() async throws -> DOMSelectionModeResult {
        throw WebInspectorCoreError.scriptUnavailable
    }

    func cancelSelectionMode() async {}

    func highlight(nodeId: Int) async {
        _ = nodeId
    }

    func hideHighlight() async {}

    func rememberPendingSelection(nodeId: Int?) {
        _ = nodeId
    }

    func removeNode(nodeId: Int) async {
        _ = nodeId
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        _ = nodeId
        return nil
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        _ = undoToken
        return false
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool {
        _ = undoToken
        _ = nodeId
        return false
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        _ = nodeId
        _ = name
        _ = value
    }

    func removeAttribute(nodeId: Int, name: String) async {
        _ = nodeId
        _ = name
    }

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        _ = nodeId
        _ = kind
        throw WebInspectorCoreError.scriptUnavailable
    }
}

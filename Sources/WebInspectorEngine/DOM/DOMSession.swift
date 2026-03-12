import WebInspectorCore
import WebKit
import WebInspectorTransport

@MainActor
public final class DOMSession {
    public typealias AttachmentResult = (shouldReload: Bool, preserveState: Bool)

    private struct DefaultPageAgentComponents {
        let pageAgent: any DOMPageDriving
        let transportCapabilityProvider: (any InspectorTransportCapabilityProviding)?
        let transportSupportSnapshot: WITransportSupportSnapshot?
    }

    public private(set) var configuration: DOMConfiguration
    public let graphStore: DOMGraphStore

    public private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: any DOMPageDriving
    private let transportCapabilityProvider: (any InspectorTransportCapabilityProviding)?
    private let fallbackTransportSupportSnapshot: WITransportSupportSnapshot?
    private var autoSnapshotEnabled = false
    package weak var eventSink: (any DOMProtocolEventSink)? {
        didSet {
            pageAgent.eventSink = eventSink
        }
    }

    public convenience init(configuration: DOMConfiguration = .init()) {
        let graphStore = DOMGraphStore()
        let components = Self.makeDefaultPageAgentComponents(
            configuration: configuration,
            graphStore: graphStore
        )
        self.init(
            configuration: configuration,
            graphStore: graphStore,
            pageAgent: components.pageAgent,
            transportCapabilityProvider: components.transportCapabilityProvider,
            transportSupportSnapshot: components.transportSupportSnapshot
        )
    }

    package convenience init(
        configuration: DOMConfiguration = .init(),
        graphStore: DOMGraphStore = DOMGraphStore(),
        defaultTransportSupportSnapshot: WITransportSupportSnapshot
    ) {
        let components = Self.makeDefaultPageAgentComponents(
            configuration: configuration,
            graphStore: graphStore,
            transportSupportSnapshot: defaultTransportSupportSnapshot
        )
        self.init(
            configuration: configuration,
            graphStore: graphStore,
            pageAgent: components.pageAgent,
            transportCapabilityProvider: components.transportCapabilityProvider,
            transportSupportSnapshot: components.transportSupportSnapshot
        )
    }

    convenience init(
        configuration: DOMConfiguration = .init(),
        graphStore: DOMGraphStore = DOMGraphStore(),
        pageAgent: any DOMPageDriving
    ) {
        self.init(
            configuration: configuration,
            graphStore: graphStore,
            pageAgent: pageAgent,
            transportCapabilityProvider: pageAgent as? (any InspectorTransportCapabilityProviding)
        )
    }

    init(
        configuration: DOMConfiguration = .init(),
        graphStore: DOMGraphStore = DOMGraphStore(),
        pageAgent: any DOMPageDriving,
        transportCapabilityProvider: (any InspectorTransportCapabilityProviding)? = nil,
        transportSupportSnapshot: WITransportSupportSnapshot? = nil
    ) {
        self.configuration = configuration
        self.graphStore = graphStore
        self.pageAgent = pageAgent
        self.transportCapabilityProvider = transportCapabilityProvider
        fallbackTransportSupportSnapshot = transportSupportSnapshot
        self.pageAgent.eventSink = eventSink
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

    package var isAutoSnapshotEnabled: Bool {
        autoSnapshotEnabled
    }

    package var transportCapabilities: Set<InspectorTransportCapability> {
        let fallbackCapabilities = Self.fallbackTransportCapabilities(from: fallbackTransportSupportSnapshot)
        guard let providerCapabilities = transportCapabilityProvider?.inspectorTransportCapabilities else {
            return fallbackCapabilities
        }
        return providerCapabilities.union(fallbackCapabilities)
    }

    public var transportSupportSnapshot: WITransportSupportSnapshot? {
        transportCapabilityProvider?.inspectorTransportSupportSnapshot ?? fallbackTransportSupportSnapshot
    }

    @discardableResult
    public func attach(to webView: WKWebView) -> AttachmentResult {
        if pageAgent.webView === webView {
            lastPageWebView = webView
            return (false, false)
        }

        graphStore.resetForDocumentUpdate()

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
        graphStore.resetForDocumentUpdate()
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

extension DOMSession {
    package func prepareForTransportRebind() {
        guard transportSupportSnapshot?.backendKind == .macOSNativeInspector else {
            return
        }

        (pageAgent as? DOMTransportRebindDriving)?.prepareForTransportRebind()
    }

    package func resumeAfterTransportRebind(
        to webView: WKWebView,
        reloadDocument: Bool = true
    ) async throws {
        guard transportSupportSnapshot?.backendKind == .macOSNativeInspector else {
            return
        }

        lastPageWebView = webView
        (pageAgent as? DOMTransportRebindDriving)?.resumeAfterTransportRebind()
        guard reloadDocument else {
            return
        }
        try await pageAgent.reloadDocument(preserveState: false, requestedDepth: nil)
    }
}

// MARK: - Snapshot API

public extension DOMSession {
    func captureSnapshot(maxDepth: Int) async throws -> String {
        try await pageAgent.captureSnapshot(maxDepth: maxDepth)
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        try await pageAgent.captureSubtree(nodeId: nodeId, maxDepth: maxDepth)
    }

    func styles(nodeId: Int, maxMatchedRules: Int = 0) async throws -> DOMNodeStylePayload {
        try await pageAgent.styles(nodeId: nodeId, maxMatchedRules: maxMatchedRules)
    }
}

// MARK: - Document API

public extension DOMSession {
    func reloadDocument(preserveState: Bool = false) async throws {
        try await pageAgent.reloadDocument(preserveState: preserveState)
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        try await pageAgent.requestChildNodes(parentNodeId: parentNodeId)
    }
}

extension DOMSession {
    package func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws {
        try await pageAgent.reloadDocument(
            preserveState: preserveState,
            requestedDepth: requestedDepth
        )
    }
}

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
    func beginSelectionMode() async throws -> DOMSelectionModeResult {
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

extension DOMSession {
    package func rememberPendingSelection(nodeId: Int?) {
        pageAgent.rememberPendingSelection(nodeId: nodeId)
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

private extension DOMSession {
    private static func fallbackTransportCapabilities(
        from snapshot: WITransportSupportSnapshot?
    ) -> Set<InspectorTransportCapability> {
        Set(snapshot?.capabilities.compactMap { InspectorTransportCapability(rawValue: $0.rawValue) } ?? [])
    }

    private static func shouldUseTransportDriver(for snapshot: WITransportSupportSnapshot) -> Bool {
        snapshot.isSupported
    }

    private static func makeDefaultPageAgentComponents(
        configuration: DOMConfiguration,
        graphStore: DOMGraphStore,
        transportSupportSnapshot: WITransportSupportSnapshot? = nil
    ) -> DefaultPageAgentComponents {
        let preflightSnapshot = transportSupportSnapshot ?? WITransportSession().supportSnapshot
        let driver: any DOMPageDriving
        let capabilityProvider: (any InspectorTransportCapabilityProviding)?

        if shouldUseTransportDriver(for: preflightSnapshot) {
            let transportDriver = DOMTransportDriver(configuration: configuration, graphStore: graphStore)
            driver = transportDriver
            capabilityProvider = transportSupportSnapshot == nil ? transportDriver : nil
        } else {
            driver = DOMLegacyPageDriver(configuration: configuration, graphStore: graphStore)
            capabilityProvider = nil
        }

        return DefaultPageAgentComponents(
            pageAgent: driver,
            transportCapabilityProvider: capabilityProvider,
            transportSupportSnapshot: preflightSnapshot
        )
    }
}

#if DEBUG
extension DOMSession {
    package func testPageAgentTypeName() -> String {
        String(describing: type(of: pageAgent))
    }
}
#endif

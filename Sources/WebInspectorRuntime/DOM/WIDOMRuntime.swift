import Foundation
import Observation
import ObservationBridge
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class WIDOMRuntime {
    private let inspector: WIDOMInspector
    @ObservationIgnored private var domTreeWebView: WKWebView?

    public let document: DOMDocumentModel

    public convenience init(
        configuration: DOMConfiguration = .init(),
        dependencies: WIInspectorDependencies = .liveValue
    ) {
        self.init(
            configuration: configuration,
            dependencies: dependencies,
            sharedTransport: dependencies.makeSharedTransport()
        )
    }

    package init(
        configuration: DOMConfiguration,
        dependencies: WIInspectorDependencies = .liveValue,
        sharedTransport: WISharedInspectorTransport
    ) {
        let inspector = WIDOMInspector(
            configuration: configuration,
            dependencies: dependencies,
            sharedTransport: sharedTransport
        )
        self.inspector = inspector
        self.document = inspector.document
    }

    isolated deinit {
        inspector.tearDownForDeinit()
    }

    public func attach(to webView: WKWebView) async {
        await inspector.attach(to: webView)
    }

    public func detach() async {
        domTreeWebView = nil
        await inspector.detach()
    }

    package func treeWebViewForPresentation() -> WKWebView {
        if let domTreeWebView {
            return domTreeWebView
        }

        let domTreeWebView = inspector.inspectorWebViewForPresentation()
        self.domTreeWebView = domTreeWebView
        return domTreeWebView
    }

    package var hasPageWebView: Bool {
        inspector.hasPageWebView
    }

    package var isPageReadyForSelection: Bool {
        inspector.isPageReadyForSelection
    }

    package var isSelectingElement: Bool {
        inspector.isSelectingElement
    }

    package func observeNavigationState(
        in scope: ObservationScope,
        _ onChange: @escaping @MainActor () -> Void
    ) {
        inspector.observe(\.hasPageWebView) { _ in onChange() }
            .store(in: scope)
        inspector.observe(\.isPageReadyForSelection) { _ in onChange() }
            .store(in: scope)
        inspector.observe(\.isSelectingElement) { _ in onChange() }
            .store(in: scope)
        document.observe(\.selectedNode) { _ in onChange() }
            .store(in: scope)
    }

    package func requestSelectionModeToggle() {
        inspector.requestSelectionModeToggle()
    }

    package func reloadPage() async throws {
        try await inspector.reloadPage()
    }

    package func reloadDocument() async throws {
        try await inspector.reloadDocument()
    }

    package func copySelectedHTML() async throws -> String {
        try await inspector.copySelectedHTML()
    }

    package func copySelectedSelectorPath() async throws -> String {
        try await inspector.copySelectedSelectorPath()
    }

    package func copySelectedXPath() async throws -> String {
        try await inspector.copySelectedXPath()
    }

    package func deleteSelectedNode(undoManager: UndoManager?) async throws {
        try await inspector.deleteNode(
            nodeID: document.selectedNode?.id,
            undoManager: undoManager
        )
    }
}

@_spi(Monocly)
public extension WIDOMRuntime {
    var hasPageWebViewForDiagnostics: Bool {
        inspector.hasPageWebView
    }

    var isSelectingElementForDiagnostics: Bool {
        inspector.isSelectingElement
    }

    func beginSelectionMode() async throws {
        try await inspector.beginSelectionMode()
    }

    func currentDocumentURLForDiagnostics() -> String? {
        inspector.currentDocumentURLForDiagnostics()
    }

    func currentContextIDForDiagnostics() -> DOMContextID? {
        inspector.currentContextIDForDiagnostics()
    }

    func currentSelectedNodePreviewForDiagnostics() -> String? {
        inspector.currentSelectedNodePreviewForDiagnostics()
    }

    func currentSelectedNodeSelectorForDiagnostics() -> String? {
        inspector.currentSelectedNodeSelectorForDiagnostics()
    }

    func currentSelectedNodeLineageForDiagnostics() -> String? {
        inspector.currentSelectedNodeLineageForDiagnostics()
    }

    func visibleNodeSummariesForDiagnostics(limit: Int = 12) -> [String] {
        inspector.visibleNodeSummariesForDiagnostics(limit: limit)
    }

    func lastSelectionDiagnosticForDiagnostics() -> String? {
        inspector.lastSelectionDiagnosticForDiagnostics()
    }

    func nativeInspectorInteractionStateForDiagnostics() -> String? {
#if canImport(UIKit)
        inspector.nativeInspectorInteractionStateForDiagnostics()
#else
        nil
#endif
    }

    func selectNodeForTesting(cssSelector: String) async throws {
        try await inspector.selectNodeForTesting(cssSelector: cssSelector)
    }

    func selectNodeForTesting(preview: String, selectorPath: String) async throws {
        try await inspector.selectNodeForTesting(
            preview: preview,
            selectorPath: selectorPath
        )
    }
}

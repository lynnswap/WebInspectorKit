import Foundation
import Observation
import ObservationBridge
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class V2_WIDOMRuntime {
    private let inspector: WIDOMInspector
    @ObservationIgnored private var domTreeWebView: WKWebView?

    public let document: DOMDocumentModel

    public convenience init(configuration: DOMConfiguration = .init()) {
        self.init(
            configuration: configuration,
            sharedTransport: WISharedInspectorTransport()
        )
    }

    package init(
        configuration: DOMConfiguration,
        sharedTransport: WISharedInspectorTransport
    ) {
        let inspector = WIDOMInspector(
            configuration: configuration,
            sharedTransport: sharedTransport
        )
        self.inspector = inspector
        self.document = inspector.document
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

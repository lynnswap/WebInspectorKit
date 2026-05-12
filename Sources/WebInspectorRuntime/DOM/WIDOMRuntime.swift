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

    public let document: DOMDocumentModel

    public convenience init(
        dependencies: WIInspectorDependencies = .liveValue
    ) {
        self.init(
            dependencies: dependencies,
            sharedTransport: dependencies.makeSharedTransport()
        )
    }

    package init(
        dependencies: WIInspectorDependencies = .liveValue,
        sharedTransport: WISharedInspectorTransport
    ) {
        let inspector = WIDOMInspector(
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
        await inspector.detach()
    }

    package func suspend() async {
        await inspector.suspend()
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

    package func selectNode(_ node: DOMNodeModel) async {
        await inspector.selectNode(node)
    }

    @discardableResult
    package func requestChildNodes(for node: DOMNodeModel, depth: Int) async -> Bool {
        await inspector.requestChildNodes(for: node, depth: depth)
    }

    package func highlightNode(_ node: DOMNodeModel, reveal: Bool) async {
        await inspector.highlightNode(node, reveal: reveal)
    }

    package func hideNodeHighlight() async {
        await inspector.hideNodeHighlight()
    }

    package func copyHTML(for node: DOMNodeModel) async throws -> String {
        try await inspector.copyNode(nodeID: node.id, kind: .html)
    }

    package func copyHTML(for nodes: [DOMNodeModel]) async throws -> String {
        var seenNodeIDs: Set<DOMNodeModel.ID> = []
        var fragments: [String] = []
        for node in nodes where seenNodeIDs.insert(node.id).inserted {
            fragments.append(try await copyHTML(for: node))
        }
        return fragments.joined(separator: "\n")
    }

    package func copySelectorPath(for node: DOMNodeModel) async throws -> String {
        try await inspector.copyNode(nodeID: node.id, kind: .selectorPath)
    }

    package func copyXPath(for node: DOMNodeModel) async throws -> String {
        try await inspector.copyNode(nodeID: node.id, kind: .xpath)
    }

    package func deleteNode(_ node: DOMNodeModel, undoManager: UndoManager?) async throws {
        try await inspector.deleteNode(nodeID: node.id, undoManager: undoManager)
    }

    package func deleteNodes(_ nodes: [DOMNodeModel], undoManager: UndoManager?) async throws {
        var seenNodeIDs: Set<DOMNodeModel.ID> = []
        let uniqueNodes = nodes.filter { seenNodeIDs.insert($0.id).inserted }
        for node in uniqueNodes.sorted(by: { $0.depthFromRoot > $1.depthFromRoot }) {
            try await deleteNode(node, undoManager: undoManager)
        }
    }
}

private extension DOMNodeModel {
    var depthFromRoot: Int {
        var depth = 0
        var current = parent
        while let ancestor = current {
            depth += 1
            current = ancestor.parent
        }
        return depth
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

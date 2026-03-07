import WebKit

@MainActor
protocol DOMPageDriving: AnyObject {
    var sink: (any DOMBundleSink)? { get set }
    var currentBridgeMode: WIBridgeMode { get }
    var webView: WKWebView? { get }

    func updateConfiguration(_ configuration: DOMConfiguration)
    func attachPageWebView(_ newWebView: WKWebView?)
    func detachPageWebView()
    func setAutoSnapshot(enabled: Bool) async

    func captureSnapshot(maxDepth: Int) async throws -> String
    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String
    func matchedStyles(nodeId: Int, maxRules: Int) async throws -> DOMMatchedStylesPayload
    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any
    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any

    func beginSelectionMode() async throws -> DOMPageAgent.SelectionModeResult
    func cancelSelectionMode() async
    func highlight(nodeId: Int) async
    func hideHighlight() async

    func removeNode(nodeId: Int) async
    func removeNodeWithUndo(nodeId: Int) async -> Int?
    func undoRemoveNode(undoToken: Int) async -> Bool
    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool
    func setAttribute(nodeId: Int, name: String, value: String) async
    func removeAttribute(nodeId: Int, name: String) async

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String
}

extension DOMPageAgent: DOMPageDriving {}

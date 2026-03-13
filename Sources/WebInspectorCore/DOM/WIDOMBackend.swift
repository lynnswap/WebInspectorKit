import WebKit

@MainActor
package protocol WIDOMBackend: AnyObject {
    var eventSink: (any WIDOMProtocolEventSink)? { get set }
    var webView: WKWebView? { get }
    var support: WIBackendSupport { get }

    func updateConfiguration(_ configuration: DOMConfiguration)
    func attachPageWebView(_ newWebView: WKWebView?)
    func detachPageWebView()
    func setAutoSnapshot(enabled: Bool) async
    func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws
    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor]

    func captureSnapshot(maxDepth: Int) async throws -> String
    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String
    func styles(nodeId: Int, maxMatchedRules: Int) async throws -> DOMNodeStylePayload
    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any
    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any

    func beginSelectionMode() async throws -> DOMSelectionModeResult
    func cancelSelectionMode() async
    func highlight(nodeId: Int) async
    func hideHighlight() async
    func rememberPendingSelection(nodeId: Int?)

    func removeNode(nodeId: Int) async
    func removeNodeWithUndo(nodeId: Int) async -> Int?
    func undoRemoveNode(undoToken: Int) async -> Bool
    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool
    func setAttribute(nodeId: Int, name: String, value: String) async
    func removeAttribute(nodeId: Int, name: String) async

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String

    func prepareForNavigationReconnect()
    func resumeAfterNavigationReconnect()
}

package extension WIDOMBackend {
    func reloadDocument(preserveState: Bool) async throws {
        try await reloadDocument(preserveState: preserveState, requestedDepth: nil)
    }

    func prepareForNavigationReconnect() {}

    func resumeAfterNavigationReconnect() {}
}

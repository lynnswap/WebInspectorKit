import WebKit
#if canImport(AppKit)
import AppKit
#endif

@MainActor
package protocol WIDOMFrontendBridge: AnyObject, WIDOMProtocolEventSink {
    var delegate: (any WIDOMFrontendBridgeDelegate)? { get set }
    var hasFrontendWebView: Bool { get }

    func makeFrontendWebView() -> WKWebView
    func detachFrontendWebView()
    func updateConfiguration(_ configuration: DOMConfiguration)
    func setPreferredDepth(_ depth: Int)
    func requestDocument(depth: Int, preserveState: Bool)
#if canImport(AppKit)
    func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?)
#endif
}

@MainActor
package protocol WIDOMFrontendBridgeDelegate: AnyObject {
    func domFrontendDidReceiveRecoverableError(_ message: String)
    func domFrontendDidMissSelectionSnapshot(_ payload: DOMSelectionSnapshotPayload)
    func domFrontendDidClearSelection()
}

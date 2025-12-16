import WebKit

@MainActor
protocol WIPageSession: AnyObject {
    associatedtype AttachmentResult = Void

    var lastPageWebView: WKWebView? { get }

    @discardableResult
    func attach(pageWebView webView: WKWebView) -> AttachmentResult

    func suspend()

    func detach()
}

import WebKit

@MainActor
protocol PageSession: AnyObject {
    associatedtype AttachmentResult = Void

    var lastPageWebView: WKWebView? { get }

    @discardableResult
    func attach(pageWebView webView: WKWebView) async -> AttachmentResult

    func suspend() async

    func detach() async
}

import WebKit

@MainActor
package protocol PageAgent: AnyObject {
    var webView: WKWebView? { get set }

    func willDetachPageWebView(_ webView: WKWebView)
    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?)
    func didClearPageWebView()
}

@MainActor
package extension PageAgent {
    func attachPageWebView(_ newWebView: WKWebView?) {
        replacePageWebView(with: newWebView)
    }

    func detachPageWebView() {
        replacePageWebView(with: nil)
    }

    func replacePageWebView(with newWebView: WKWebView?) {
        guard self.webView !== newWebView else { return }

        let previousWebView = self.webView
        if let previousWebView {
            willDetachPageWebView(previousWebView)
        }

        guard let newWebView else {
            self.webView = nil
            didClearPageWebView()
            return
        }

        self.webView = newWebView
        didAttachPageWebView(newWebView, previousWebView: previousWebView)
    }
}

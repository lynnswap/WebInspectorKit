#if DEBUG
import WebKit

@_spi(PreviewSupport)
public extension WIDOMStore {
    func wiAttachPreviewPageWebView(_ webView: WKWebView) {
        attach(to: webView)
    }
}
#endif

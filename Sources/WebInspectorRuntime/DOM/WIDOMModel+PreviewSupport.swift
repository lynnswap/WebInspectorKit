#if DEBUG
import WebKit

@_spi(PreviewSupport)
public extension WIDOMModel {
    func wiAttachPreviewPageWebView(_ webView: WKWebView) {
        attach(to: webView)
    }
}
#endif

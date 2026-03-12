#if DEBUG
import WebKit

@_spi(PreviewSupport)
public extension WIDOMInspectorStore {
    func wiAttachPreviewPageWebView(_ webView: WKWebView) {
        attach(to: webView)
    }
}
#endif

#if DEBUG
import WebKit
import WebInspectorEngine

@_spi(PreviewSupport)
public extension WIDOMModel {
    func wiAttachPreviewPageWebView(_ webView: WKWebView) async {
        await attach(to: webView)
    }
}
#endif

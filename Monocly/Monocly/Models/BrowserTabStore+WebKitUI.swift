import OSLog
import UIKit
import WebKit

extension BrowserTabStore: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
            return nil
        }
        logger.debug("\(#function) handle new window in existing webView: \(url.absoluteString, privacy: .public)")
        webView.load(URLRequest(url: url))
        return nil
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void
    ) {
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak webView] suggestedActions in
            guard let linkURL = elementInfo.linkURL else {
                return UIMenu(title: "", children: suggestedActions)
            }

            let openInAppAction = UIAction(
                title: String(localized: "monocly.context.open_in_monocly", bundle: .main),
                image: UIImage(systemName: "safari")
            ) { _ in
                guard let webView else {
                    return
                }
                logger.debug("Open link in-app from context menu: \(linkURL.absoluteString, privacy: .public)")
                webView.load(URLRequest(url: linkURL))
            }

            return UIMenu(title: "", children: [openInAppAction] + suggestedActions)
        }

        completionHandler(configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        logger.debug("\(#function) WebView closed")
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        logger.debug("\(#function) JavaScript alert: \(message, privacy: .public)")
        await presentJavaScriptAlert(message: message, webView: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        logger.debug("\(#function) JavaScript confirm: \(message, privacy: .public)")
        return await presentJavaScriptConfirm(message: message, webView: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        logger.debug("\(#function) JavaScript prompt: \(prompt, privacy: .public)")
        return await presentJavaScriptPrompt(prompt: prompt, defaultText: defaultText, webView: webView)
    }
}

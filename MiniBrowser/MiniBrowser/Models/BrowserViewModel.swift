import Foundation
import Observation
import WebKit
import SwiftUI
import Combine

import OSLog

private let logger = Logger(
    subsystem: "MiniBrowser",
    category: "BrowserViewModel"
)

@MainActor
@Observable final class BrowserViewModel: NSObject {
    let webView: WKWebView
    var canGoBack = false
    var canGoForward = false
    var estimatedProgress: Double = .zero
    var isLoading = false
    var currentURL :URL?
    var underPageBackgroundColor: Color?
#if os(iOS)
    private var refreshControl: UIRefreshControl?
#endif
    
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    
    var isShowingProgress: Bool {
        isLoading && estimatedProgress < 1.0
    }
    
    init(url: URL) {
        currentURL = url
        let configuration = WKWebViewConfiguration()
        
#if os(iOS)
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsInlineMediaPlayback = true
#endif
        configuration.allowsAirPlayForMediaPlayback = true
        
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
#if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.scrollView.clipsToBounds = false
        webView.customUserAgent =  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"
#else
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
#endif
        webView.allowsBackForwardNavigationGestures = true

        super.init()
#if os(iOS)
        configureRefreshControl()
#endif
        
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        setObservers()
        webView.load(URLRequest(url: url))
    }

    private func setObservers() {
        cancellables.removeAll()

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.estimatedProgress = progress
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.currentURL = url
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoForward in
                self?.canGoForward = canGoForward
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoBack in
                self?.canGoBack = canGoBack
            }
            .store(in: &cancellables)

        webView.publisher(for: \.underPageBackgroundColor, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] underPageBackgroundColor in
                self?.underPageBackgroundColor = underPageBackgroundColor.map(Color.init)
            }
            .store(in: &cancellables)
    }
    
    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }
    
    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }
#if os(iOS)
    private func configureRefreshControl() {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
        webView.scrollView.refreshControl = control
        refreshControl = control
    }
    
    @objc private func handleRefreshControl() {
        webView.reload()
    }
    
    private func endRefreshingIfNeeded() {
        guard let refreshControl, refreshControl.isRefreshing else {
            return
        }
        refreshControl.endRefreshing()
    }
#endif
}

extension BrowserViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        logger.debug("\(#function) decide navigation policy (action)")
#if os(macOS)
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           navigationAction.targetFrame?.isMainFrame != false {
            webView.load(URLRequest(url: url))
            return .cancel
        }
#endif
        return .allow
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logger.debug("\(#function) provisional navigation started")
        isLoading = true
        estimatedProgress = .zero
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        return .allow
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logger.debug("\(#function) navigation committed")
    }
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?){
        logger.debug("\(#function) authentication challenge")
        return(.useCredential, nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError: Error) {
        logger.debug("\(#function) provisional navigation failed")
        isLoading = false
        estimatedProgress = .zero
#if os(iOS)
        endRefreshingIfNeeded()
#endif
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError: Error) {
        logger.debug("\(#function) navigation failed")
        isLoading = false
#if os(iOS)
        endRefreshingIfNeeded()
#endif
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation:WKNavigation!) {
        logger.debug("\(#function) server redirect for provisional navigation")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.debug("\(#function) web content process terminated")
        isLoading = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = .zero
#if os(iOS)
        endRefreshingIfNeeded()
#endif
    }
}

extension BrowserViewModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
            return nil
        }
        logger.debug("\(#function) handle new window in existing webView: \(url.absoluteString, privacy: .public)")
        webView.load(URLRequest(url: url))
        return nil
    }

#if os(iOS)
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
                title: "Open in MiniBrowser",
                image: UIImage(systemName: "safari")
            ) { _ in
                guard let webView else { return }
                logger.debug("Open link in-app from context menu: \(linkURL.absoluteString, privacy: .public)")
                webView.load(URLRequest(url: linkURL))
            }

            return UIMenu(title: "", children: [openInAppAction] + suggestedActions)
        }

        completionHandler(configuration)
    }
#endif

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

private extension BrowserViewModel {
#if os(iOS)
    @MainActor
    func presentJavaScriptAlert(message: String, webView: WKWebView) async {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("alert presenter not found; ignoring alert")
            return
        }
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume()
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func presentJavaScriptConfirm(message: String, webView: WKWebView) async -> Bool {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("confirm presenter not found; denying")
            return false
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, webView: WKWebView) async -> String? {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("prompt presenter not found; denying")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = defaultText
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }

    func findPresenter(for webView: WKWebView) -> UIViewController? {
        var responder: UIResponder? = webView
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return webView.window?.rootViewController
    }
#else
    @MainActor
    func presentJavaScriptAlert(message: String, webView: WKWebView) async {
        guard let window = webView.window else {
            logger.error("alert window not found; ignoring alert")
            return
        }
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    func presentJavaScriptConfirm(message: String, webView: WKWebView) async -> Bool {
        guard let window = webView.window else {
            logger.error("confirm window not found; denying")
            return false
        }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    @MainActor
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, webView: WKWebView) async -> String? {
        guard let window = webView.window else {
            logger.error("prompt window not found; denying")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let textField = NSTextField(string: defaultText ?? "")
            alert.accessoryView = textField
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: textField.stringValue)
            }
        }
    }
#endif
}

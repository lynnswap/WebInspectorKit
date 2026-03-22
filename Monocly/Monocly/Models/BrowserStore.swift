import Combine
import Foundation
import Observation
import OSLog
import WebKit

#if canImport(UIKit)
import UIKit
typealias BrowserPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
typealias BrowserPlatformColor = NSColor
#endif

private let logger = Logger(
    subsystem: "Monocly",
    category: "BrowserStore"
)

@MainActor
@Observable final class BrowserStore: NSObject {
    let webView: WKWebView
    private let initialURL: URL

    var canGoBack = false
    var canGoForward = false
    var estimatedProgress: Double = .zero
    var isLoading = false
    var currentURL: URL?
    var underPageBackgroundColor: BrowserPlatformColor?
    var webContentTerminationCount = 0
    var lastWebContentTerminationDate: Date?
    var lastWebContentTerminationURL: URL?
    var lastNavigationErrorDescription: String?
    var didFinishNavigationCount = 0

#if canImport(UIKit)
    private var refreshControl: UIRefreshControl?
#endif

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var stateObserverByID: [UUID: () -> Void] = [:]
    @ObservationIgnored private var hasLoadedInitialRequest = false

    var isShowingProgress: Bool {
        isLoading && estimatedProgress < 1.0
    }

    var displayTitle: String {
        if let host = currentURL?.host(), host.isEmpty == false {
            return host
        }
        if let currentURL {
            if currentURL.isFileURL {
                return currentURL.lastPathComponent
            }
            return currentURL.absoluteString
        }
        return "Monocly"
    }

    init(url: URL, automaticallyLoadsInitialRequest: Bool = true) {
        initialURL = url
        currentURL = url

        let configuration = WKWebViewConfiguration()
#if canImport(UIKit)
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsInlineMediaPlayback = true
#endif
        configuration.allowsAirPlayForMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
#if canImport(UIKit)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"
#else
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"
#endif
        webView.allowsBackForwardNavigationGestures = true

        super.init()
#if canImport(UIKit)
        configureRefreshControl()
#endif

        webView.navigationDelegate = self
        webView.uiDelegate = self

        setObservers()
        if automaticallyLoadsInitialRequest {
            loadInitialRequestIfNeeded()
        }
    }

    @discardableResult
    func addStateObserver(_ observer: @escaping () -> Void) -> UUID {
        let observerID = UUID()
        stateObserverByID[observerID] = observer
        observer()
        return observerID
    }

    func removeStateObserver(_ observerID: UUID) {
        stateObserverByID.removeValue(forKey: observerID)
    }

    func goBack() {
        guard webView.canGoBack else {
            return
        }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else {
            return
        }
        webView.goForward()
    }

    func loadInitialRequestIfNeeded() {
        guard hasLoadedInitialRequest == false else {
            return
        }

        hasLoadedInitialRequest = true
        webView.load(URLRequest(url: initialURL))
    }

    private func setObservers() {
        cancellables.removeAll()

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                guard let self else {
                    return
                }
                self.estimatedProgress = progress
                self.notifyStateObservers()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self else {
                    return
                }
                self.currentURL = url
                self.notifyStateObservers()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoForward in
                guard let self else {
                    return
                }
                self.canGoForward = canGoForward
                self.notifyStateObservers()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canGoBack in
                guard let self else {
                    return
                }
                self.canGoBack = canGoBack
                self.notifyStateObservers()
            }
            .store(in: &cancellables)

        webView.publisher(for: \.underPageBackgroundColor, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] underPageBackgroundColor in
                guard let self else {
                    return
                }
                self.underPageBackgroundColor = underPageBackgroundColor
                self.notifyStateObservers()
            }
            .store(in: &cancellables)
    }

    private func notifyStateObservers() {
        for observer in stateObserverByID.values {
            observer()
        }
    }

#if canImport(UIKit)
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

extension BrowserStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        logger.debug("\(#function) decide navigation policy (action)")
#if canImport(AppKit)
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
        notifyStateObservers()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logger.debug("\(#function) navigation committed")
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        logger.debug("\(#function) authentication challenge")
        return (.useCredential, nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError navigationError: Error) {
        logger.debug("\(#function) provisional navigation failed")
        isLoading = false
        estimatedProgress = .zero
        lastNavigationErrorDescription = navigationError.localizedDescription
#if canImport(UIKit)
        endRefreshingIfNeeded()
#endif
        notifyStateObservers()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError navigationError: Error) {
        logger.debug("\(#function) navigation failed")
        isLoading = false
        lastNavigationErrorDescription = navigationError.localizedDescription
#if canImport(UIKit)
        endRefreshingIfNeeded()
#endif
        notifyStateObservers()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        logger.debug("\(#function) server redirect for provisional navigation")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.debug("\(#function) web content process terminated")
        isLoading = false
        webContentTerminationCount += 1
        lastWebContentTerminationDate = Date()
        lastWebContentTerminationURL = webView.url
        notifyStateObservers()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = .zero
        lastNavigationErrorDescription = nil
        didFinishNavigationCount += 1
#if canImport(UIKit)
        endRefreshingIfNeeded()
#endif
        notifyStateObservers()
    }
}

extension BrowserStore: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
            return nil
        }
        logger.debug("\(#function) handle new window in existing webView: \(url.absoluteString, privacy: .public)")
        webView.load(URLRequest(url: url))
        return nil
    }

#if canImport(UIKit)
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
                title: "Open in Monocly",
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

private extension BrowserStore {
#if canImport(UIKit)
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

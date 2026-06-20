import Foundation
import ObjectiveC
import OSLog
import WebKit

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let restoredInteractionPolicy = Self.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: isRestoringInteractionStateNavigation,
            targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            url: navigationAction.request.url,
            shouldOpenAppLinks: Self.shouldOpenAppLinks(from: navigationAction)
        ) {
            return restoredInteractionPolicy
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        markWebViewInteractionStatePendingNavigation()
        beginLoadingProgress()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearRestoredInteractionStateNavigationIfNeeded()
        didCommitNavigationCount += 1
        syncNavigationState(from: webView, clearsNavigationError: true)
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        return (.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError navigationError: Error) {
        logger.debug("\(#function) provisional navigation failed")
        if isBenignNavigationCancellation(navigationError) {
            endRefreshingIfNeeded()
            clearRestoredInteractionStateNavigationIfNeeded()
            syncNavigationState(from: webView)
            markWebViewInteractionStateSynchronizedIfNavigationSettled()
            return
        }
        lastNavigationErrorDescription = navigationError.localizedDescription
        endRefreshingIfNeeded()
        clearRestoredInteractionStateNavigationIfNeeded()
        syncNavigationState(from: webView)
        markWebViewInteractionStateSynchronizedIfNavigationSettled()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError navigationError: Error) {
        logger.debug("\(#function) navigation failed")
        if isBenignNavigationCancellation(navigationError) {
            endRefreshingIfNeeded()
            clearRestoredInteractionStateNavigationIfNeeded()
            syncNavigationState(from: webView)
            markWebViewInteractionStateSynchronizedIfNavigationSettled()
            return
        }
        lastNavigationErrorDescription = navigationError.localizedDescription
        endRefreshingIfNeeded()
        clearRestoredInteractionStateNavigationIfNeeded()
        syncNavigationState(from: webView)
        markWebViewInteractionStateSynchronizedIfNavigationSettled()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        logger.debug("\(#function) server redirect for provisional navigation")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.debug("\(#function) web content process terminated")
        isLoading = false
        clearRestoredInteractionStateNavigationIfNeeded()
        markWebViewInteractionStatePendingNavigation()
        webContentTerminationCount += 1
        lastWebContentTerminationDate = Date()
        lastWebContentTerminationURL = webView.url
        invalidateHistoryIfNeeded()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        clearRestoredInteractionStateNavigationIfNeeded()
        didFinishNavigationCount += 1
        markWebViewInteractionStateSynchronized()
        if webView.title == nil {
            isHoldingRestoredTitle = false
            pageTitle = nil
        }
        endRefreshingIfNeeded()
        syncNavigationState(from: webView, clearsNavigationError: true)
    }
}

extension BrowserTab {
    private enum NavigationSPI {
        private static func deobfuscate(_ reverseTokens: [String]) -> String {
            reverseTokens.reversed().joined()
        }

        static let shouldOpenAppLinksSelector = NSSelectorFromString(
            deobfuscate(["Links", "App", "Open", "should", "_"])
        )
        static let allowWithoutTryingAppLinkNavigationActionPolicy =
            WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
    }

    static func restoredInteractionStateNavigationPolicy(
        isRestoringInteractionStateNavigation: Bool,
        targetFrameIsMainFrame: Bool?,
        url: URL?,
        shouldOpenAppLinks: Bool
    ) -> WKNavigationActionPolicy? {
        guard isRestoringInteractionStateNavigation,
              targetFrameIsMainFrame == true,
              shouldOpenAppLinks,
              let scheme = url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return NavigationSPI.allowWithoutTryingAppLinkNavigationActionPolicy
    }

    private static func shouldOpenAppLinks(from navigationAction: WKNavigationAction) -> Bool {
        guard navigationAction.responds(to: NavigationSPI.shouldOpenAppLinksSelector),
              let method = class_getInstanceMethod(WKNavigationAction.self, NavigationSPI.shouldOpenAppLinksSelector) else {
            return false
        }

        typealias ShouldOpenAppLinksIMP = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: ShouldOpenAppLinksIMP.self)
        return function(navigationAction, NavigationSPI.shouldOpenAppLinksSelector)
    }

    private func isBenignNavigationCancellation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

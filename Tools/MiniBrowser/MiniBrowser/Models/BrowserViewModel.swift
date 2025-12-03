import Foundation
import Combine
import Observation
import WebKit
import SwiftUI

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
    
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    
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
        
        setObservers()
        webView.load(URLRequest(url: url))
    }
    
    private func setObservers() {
        webView.publisher(for: \.estimatedProgress)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.estimatedProgress = newValue
            }
            .store(in: &cancellables)
        
        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.currentURL = newValue
            }
            .store(in: &cancellables)
        
        webView.publisher(for: \.canGoForward)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.canGoForward = newValue
            }
            .store(in: &cancellables)
        
        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.canGoBack = newValue
            }
            .store(in: &cancellables)
        
        webView.publisher(for: \.underPageBackgroundColor)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.underPageBackgroundColor = Color(newValue)
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
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy{
        logger.debug("\(#function) 読み込み設定（リクエスト前）")
        return .allow
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logger.debug("\(#function) 読み込み準備開始")
        isLoading = true
        estimatedProgress = .zero
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        return .allow
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logger.debug("\(#function) 読み込み開始")
    }
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?){
        logger.debug("\(#function) ユーザ認証")
        return(.useCredential, nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError: Error) {
        logger.debug("\(#function) 読み込み失敗検知")
        isLoading = false
        estimatedProgress = .zero
#if os(iOS)
        endRefreshingIfNeeded()
#endif
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError: Error) {
        logger.debug("\(#function) 読み込み失敗")
        isLoading = false
#if os(iOS)
        endRefreshingIfNeeded()
#endif
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation:WKNavigation!) {
        logger.debug("\(#function) リダイレクト")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        estimatedProgress = .zero
#if os(iOS)
        endRefreshingIfNeeded()
#endif
    }
}

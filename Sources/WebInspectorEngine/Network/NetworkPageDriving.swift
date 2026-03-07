import WebKit

@MainActor
protocol NetworkPageDriving: AnyObject, NetworkBodyFetching {
    var webView: WKWebView? { get }
    var store: NetworkStore { get }

    func setMode(_ mode: NetworkLoggingMode)
    func attachPageWebView(_ newWebView: WKWebView?)
    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?)
    func clearNetworkLogs()
}

extension NetworkPageAgent: NetworkPageDriving {}

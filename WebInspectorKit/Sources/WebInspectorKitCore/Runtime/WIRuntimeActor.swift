import Foundation
import WebKit

@MainActor
public protocol WIPageRuntimeBridge: AnyObject, Sendable {
    var pageWebView: WKWebView? { get }
}

@MainActor
public final class WIWeakPageRuntimeBridge: WIPageRuntimeBridge {
    public weak var pageWebView: WKWebView?

    public init(pageWebView: WKWebView? = nil) {
        self.pageWebView = pageWebView
    }

    public func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
    }
}

public enum WISessionLifecycle: String, Sendable {
    case active
    case suspended
    case disconnected
}

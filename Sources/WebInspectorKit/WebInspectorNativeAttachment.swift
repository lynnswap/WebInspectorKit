#if canImport(UIKit)
import WebKit
import WebInspectorCore
import WebInspectorNativeTransport
import WebInspectorUI

extension WebInspectorSession {
    public func attach(to webView: WKWebView) async throws {
        try await attachPresentation(to: webView) { inspector, webView in
            try await inspector.attach(to: webView)
        }
    }
}

extension WebInspectorViewController {
    public func attach(to webView: WKWebView) async throws {
        try await attachPresentation(to: webView) { inspector, webView in
            try await inspector.attach(to: webView)
        }
    }
}
#endif

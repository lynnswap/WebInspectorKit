import Foundation
import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorEngine

@MainActor
struct DOMPageBridgeTests {
    @Test
    func installOrUpdateBootstrapAppliesContextID() async throws {
        let bridge = DOMPageBridge(configuration: .init(snapshotDepth: 4, subtreeDepth: 3))
        let webView = makeIsolatedTestWebView()

        await bridge.installOrUpdateBootstrap(
            on: webView,
            contextID: 7,
            autoSnapshotEnabled: false
        )
        try await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)

        let context = await bridge.readContext(on: webView)
        #expect(context?.contextID == 7)
    }
}

@MainActor
private extension DOMPageBridgeTests {
    func loadHTML(_ html: String, in webView: WKWebView) async throws {
        let delegate = HTMLLoadDelegate()
        webView.navigationDelegate = delegate
        let delegateObject = delegate
        defer {
            webView.navigationDelegate = nil
            _ = delegateObject
        }
        try await withCheckedThrowingContinuation { continuation in
            delegate.didFinish = {
                continuation.resume(returning: ())
            }
            delegate.didFail = { error in
                continuation.resume(throwing: error)
            }
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
        }
    }
}

@MainActor
private final class HTMLLoadDelegate: NSObject, WKNavigationDelegate {
    var didFinish: (() -> Void)?
    var didFail: ((Error) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        didFail?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        didFail?(error)
    }
}

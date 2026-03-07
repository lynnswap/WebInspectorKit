#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import WebInspectorTransport

@MainActor
struct WITransportSessionMacOSTests {
    @Test
    func domEnableFailsWhenSessionIsNotAttached() async throws {
        let session = WITransportSession()

        do {
            _ = try await session.page.send(WITransportCommands.DOM.Enable())
            Issue.record("Expected DOM.Enable to fail before attach")
        } catch let error as WITransportError {
            guard case .notAttached = error else {
                Issue.record("Expected notAttached, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected WITransportError.notAttached, got \(error)")
        }
    }

    @Test
    func sessionAttachesToWKWebViewAndReadsDOM() async throws {
        let webView = WKWebView(frame: .zero)
        webView.isInspectable = true
        try await loadHTML("<html><body><p id='greeting'>Hello transport</p></body></html>", in: webView)

        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(15),
                eventBufferLimit: 64,
                dropEventsWithoutSubscribers: true
            )
        )

        try await session.attach(to: webView)
        defer {
            session.detach()
        }

        _ = try await session.page.send(WITransportCommands.DOM.Enable())
        let document = try await session.page.send(WITransportCommands.DOM.GetDocument(depth: 4))
        let outerHTML = try await session.page.send(
            WITransportCommands.DOM.GetOuterHTML(nodeId: document.root.nodeId)
        )

        #expect(document.root.nodeName == "#document")
        #expect(outerHTML.outerHTML.contains("Hello transport"))
    }
}

@MainActor
private extension WITransportSessionMacOSTests {
    func loadHTML(_ html: String, in webView: WKWebView) async throws {
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif

import Testing
import WebKit
@testable import WebInspectorEngine

@MainActor
struct NetworkLegacyPageDriverTests {
    @Test
    func postedNetworkBatchIsLoggedByLegacyDriver() async throws {
        let driver = NetworkLegacyPageDriver()
        let (webView, _) = makeTestWebView()
        defer { driver.detachPageWebView(preparing: .stopped) }

        driver.attachPageWebView(webView)
        await driver.waitForPendingConfigurationForTesting()
        await loadHTML("<html><body><p>legacy driver</p></body></html>", in: webView)
        await waitForLegacyNetworkBootstrap(in: webView)

        driver.testHandleNetworkEventsPayload([
            "authToken": driver.testAuthToken(),
            "version": 1,
            "sessionId": "legacy-session",
            "seq": 1,
            "events": [
                [
                    "kind": "requestWillBeSent",
                    "requestId": 101,
                    "url": "https://example.com/legacy",
                    "method": "GET",
                    "time": ["monotonicMs": 1_000, "wallMs": 1_700_000_000_000],
                ],
                [
                    "kind": "responseReceived",
                    "requestId": 101,
                    "status": 200,
                    "statusText": "ok",
                    "mimeType": "text/plain",
                    "headers": [:],
                    "time": ["monotonicMs": 1_010, "wallMs": 1_700_000_000_010],
                ],
                [
                    "kind": "loadingFinished",
                    "requestId": 101,
                    "time": ["monotonicMs": 1_020, "wallMs": 1_700_000_000_020],
                ],
            ],
        ])

        var completed = false
        for _ in 0..<512 {
            if driver.store.entry(forRequestID: 101, sessionID: "legacy-session")?.phase == .completed {
                completed = true
                break
            }
            await Task.yield()
        }
        #expect(completed)
    }
}

@MainActor
private final class RecordingNetworkUserContentController: WKUserContentController {
}

@MainActor
private func makeTestWebView() -> (WKWebView, RecordingNetworkUserContentController) {
    let controller = RecordingNetworkUserContentController()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController = controller
    let webView = WKWebView(frame: .zero, configuration: configuration)
    return (webView, controller)
}

@MainActor
private func loadHTML(_ html: String, in webView: WKWebView) async {
    let navigationDelegate = NetworkLegacyNavigationDelegate()
    webView.navigationDelegate = navigationDelegate

    await withCheckedContinuation { continuation in
        navigationDelegate.continuation = continuation
        webView.loadHTMLString(html, baseURL: nil)
    }
}

@MainActor
private func waitForLegacyNetworkBootstrap(in webView: WKWebView) async {
    for _ in 0..<200 {
        let raw = try? await webView.evaluateJavaScript(
            """
            (() => ({
                tokenReady: Boolean(window.__wiNetworkControlToken),
                handlerReady: Boolean(window.webkit?.messageHandlers?.webInspectorNetworkEvents),
                agentReady: Boolean(window.webInspectorNetworkAgent?.__installed)
            }))();
            """,
            in: nil,
            contentWorld: .page
        )
        let payload = raw as? NSDictionary
        let tokenReady = (payload?["tokenReady"] as? Bool) ?? ((payload?["tokenReady"] as? NSNumber)?.boolValue ?? false)
        let handlerReady = (payload?["handlerReady"] as? Bool) ?? ((payload?["handlerReady"] as? NSNumber)?.boolValue ?? false)
        let agentReady = (payload?["agentReady"] as? Bool) ?? ((payload?["agentReady"] as? NSNumber)?.boolValue ?? false)
        if tokenReady && handlerReady && agentReady {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private final class NetworkLegacyNavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _ = webView
        _ = navigation
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        _ = webView
        _ = navigation
        _ = error
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        _ = webView
        _ = navigation
        _ = error
        continuation?.resume()
        continuation = nil
    }
}

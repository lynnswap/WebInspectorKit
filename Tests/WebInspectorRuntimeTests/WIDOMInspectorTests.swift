import Testing
import WebKit
@testable import WebInspectorRuntime

@MainActor
@Suite(.serialized)
struct WIDOMInspectorTests {
    @Test
    func sameWebViewReattachKeepsContextID() async {
        let inspector = WIDOMInspector()
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let firstContextID = inspector.testCurrentContextID
        await inspector.attach(to: webView)

        #expect(inspector.testCurrentContextID == firstContextID)
        #expect(inspector.hasPageWebView == true)
    }

    @Test
    func switchingWebViewsAdvancesContextID() async throws {
        let inspector = WIDOMInspector()
        _ = inspector.makeInspectorWebView()
        let firstWebView = makeTestWebView()
        let secondWebView = makeTestWebView()

        await inspector.attach(to: firstWebView)
        let firstContextID = try #require(inspector.testCurrentContextID)

        await inspector.attach(to: secondWebView)
        let secondContextID = try #require(inspector.testCurrentContextID)

        #expect(secondContextID > firstContextID)
    }

    @Test
    func reloadDocumentWithoutPageThrowsPageUnavailable() async {
        let inspector = WIDOMInspector()

        await #expect(throws: DOMOperationError.pageUnavailable) {
            try await inspector.reloadDocument()
        }
    }

    @Test
    func suspendClearsAttachedPageWebView() async {
        let inspector = WIDOMInspector()
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        #expect(inspector.hasPageWebView == true)

        await inspector.suspend()

        #expect(inspector.hasPageWebView == false)
        #expect(inspector.testCurrentContextID == nil)
    }

    @Test
    func reloadDocumentPreservesCurrentContextOwnership() async throws {
        let inspector = WIDOMInspector()
        let inspectorWebView = inspector.makeInspectorWebView()
        let pageWebView = makeTestWebView()

        _ = inspectorWebView
        await inspector.attach(to: pageWebView)
        await loadHTML(
            """
            <html>
              <body>
                <main id="root"><div id="target">Target</div></main>
              </body>
            </html>
            """,
            in: pageWebView
        )

        let initialContextID = inspector.testCurrentContextID
        try await inspector.reloadDocument()
        #expect(inspector.hasPageWebView == true)
        #expect(inspector.testCurrentContextID != initialContextID)
    }

}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

@MainActor
private func loadHTML(_ html: String, in webView: WKWebView) async {
    let delegate = NavigationDelegate()
    webView.navigationDelegate = delegate
    await delegate.load(html: html, in: webView)
}

@MainActor
private func waitForCondition(
    maxAttempts: Int = 200,
    intervalNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxAttempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return condition()
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(html: String, in webView: WKWebView) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}

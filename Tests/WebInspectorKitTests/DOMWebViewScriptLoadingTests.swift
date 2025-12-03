import Testing
import WebKit
@testable import WebInspectorKit

@MainActor
struct DOMWebViewScriptLoadingTests {
    @Test
    func installsInspectorAgentIntoPageContentWorld() async throws {
        let webView = makeTestWebView()
        let contentModel = WIContentModel()
        contentModel.attachPageWebView(webView)
        defer { contentModel.detachPageWebView() }

        try await loadHTML(
            """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"></head>
            <body><div id="root">Hello</div></body>
            </html>
            """,
            into: webView
        )
        try await waitForInspectorAgent(in: webView)

        let installed = try await inspectorIsInstalled(in: webView)
        #expect(installed, "Inspector agent should be installed in the page content world")
    }

    @Test
    func installsNetworkAgentOnDemand() async throws {
        let webView = makeTestWebView()
        let contentModel = WIContentModel()
        contentModel.attachPageWebView(webView)
        defer { contentModel.detachPageWebView() }

        try await loadHTML(
            """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"></head>
            <body><div id="root">Hello</div></body>
            </html>
            """,
            into: webView
        )

        let installedBefore = try await networkAgentIsInstalled(in: webView)
        #expect(installedBefore == false, "Network agent should not be installed until enabled")

        await contentModel.setNetworkLoggingEnabled(true)
        try await waitForNetworkAgent(in: webView)

        let installedAfter = try await networkAgentIsInstalled(in: webView)
        #expect(installedAfter, "Network agent should install after enabling logging")
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func loadHTML(_ html: String, into webView: WKWebView) async throws {
        guard webView.loadHTMLString(html, baseURL: nil) != nil else {
            throw TestError.navigationFailed
        }
        try await waitForDocumentReady(in: webView)
    }

    private func waitForDocumentReady(in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var lastError: Error?

        while ContinuousClock.now < deadline {
            do {
                let state = try await webView.callAsyncJavaScript(
                    "return document.readyState;",
                    in: nil,
                    contentWorld: .page
                ) as? String ?? ""
                if state == "interactive" || state == "complete" {
                    return
                }
                lastError = nil
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw lastError ?? TestError.navigationTimeout
    }

    private func waitForInspectorAgent(in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var lastError: Error?

        while ContinuousClock.now < deadline {
            do {
                if try await inspectorIsInstalled(in: webView) {
                    return
                }
                lastError = nil
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw lastError ?? TestError.inspectorUnavailable
    }

    private func waitForNetworkAgent(in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var lastError: Error?

        while ContinuousClock.now < deadline {
            do {
                if try await networkAgentIsInstalled(in: webView) {
                    return
                }
                lastError = nil
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw lastError ?? TestError.networkInspectorUnavailable
    }

    private func inspectorIsInstalled(in webView: WKWebView) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            "return Boolean(window.webInspectorKit && window.webInspectorKit.__installed);",
            in: nil,
            contentWorld: .page
        )
        return (result as? Bool) ?? false
    }

    private func networkAgentIsInstalled(in webView: WKWebView) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            "return Boolean(window.webInspectorNetwork && window.webInspectorNetwork.__installed);",
            in: nil,
            contentWorld: .page
        )
        return (result as? Bool) ?? false
    }

    private enum TestError: Error {
        case navigationFailed
        case navigationTimeout
        case inspectorUnavailable
        case networkInspectorUnavailable
    }
}

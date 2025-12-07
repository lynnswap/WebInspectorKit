import Testing
import WebKit
@testable import WebInspectorKit

@MainActor
struct WIDOMPageAgentTests {
    @Test
    func didClearPageWebViewClearsSelection() {
        let agent = WIDOMPageAgent(configuration: .init(snapshotDepth: 3, subtreeDepth: 2))
        agent.selection.nodeId = 42
        agent.selection.preview = "<div>"
        agent.selection.attributes = [WIDOMAttribute(nodeId: 42, name: "class", value: "title")]
        agent.selection.path = ["html", "body", "div"]
        agent.selection.selectorPath = "#title"

        agent.didClearPageWebView()

        #expect(agent.selection.nodeId == nil)
        #expect(agent.selection.preview.isEmpty)
        #expect(agent.selection.attributes.isEmpty)
        #expect(agent.selection.path.isEmpty)
        #expect(agent.selection.selectorPath.isEmpty)
    }

    @Test
    func beginSelectionModeWithoutWebViewThrows() async {
        let agent = WIDOMPageAgent(configuration: .init())
        await #expect(throws: WIError.scriptUnavailable) {
            _ = try await agent.beginSelectionMode()
        }
    }

    @Test
    func captureSnapshotWithoutWebViewThrows() async {
        let agent = WIDOMPageAgent(configuration: .init(snapshotDepth: 2))
        await #expect(throws: WIError.scriptUnavailable) {
            _ = try await agent.captureSnapshot()
        }
    }

    @Test
    func selectionCopyTextWithoutWebViewThrows() async {
        let agent = WIDOMPageAgent(configuration: .init())
        await #expect(throws: WIError.scriptUnavailable) {
            _ = try await agent.selectionCopyText(for: 1, kind: .html)
        }
    }

    @Test
    func attachRegistersHandlersAndInstallsUserScripts() {
        let agent = WIDOMPageAgent(configuration: .init())
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)

        let addedHandlerNames = controller.addedHandlers.map(\.name)
        #expect(addedHandlerNames.contains("webInspectorSnapshotUpdate"))
        #expect(addedHandlerNames.contains("webInspectorMutationUpdate"))
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.contains { $0.source.contains("webInspectorKit") })
    }

    @Test
    func detachRemovesHandlersAndClearsWebView() {
        let agent = WIDOMPageAgent(configuration: .init())
        let (webView, controller) = makeTestWebView()

        agent.attachPageWebView(webView)
        agent.detachPageWebView()

        let removedHandlerNames = controller.removedHandlers.map(\.name)
        #expect(removedHandlerNames.contains("webInspectorSnapshotUpdate"))
        #expect(removedHandlerNames.contains("webInspectorMutationUpdate"))
        #expect(agent.webView == nil)
    }

    @Test
    func attachInstallsInspectorScriptIntoPage() async throws {
        let agent = WIDOMPageAgent(configuration: .init())
        let (webView, _) = makeTestWebView()

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)

        let raw = try await webView.evaluateJavaScript(
            "(() => Boolean(window.webInspectorKit && window.webInspectorKit.__installed))();",
            in: nil,
            contentWorld: .page
        )
        let installed = (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        #expect(installed == true)
    }

    private func makeTestWebView() -> (WKWebView, RecordingUserContentController) {
        let controller = RecordingUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return (webView, controller)
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

private final class RecordingUserContentController: WKUserContentController {
    private(set) var addedHandlers: [(name: String, world: WKContentWorld)] = []
    private(set) var removedHandlers: [(name: String, world: WKContentWorld)] = []

    override func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld: WKContentWorld, name: String) {
        addedHandlers.append((name, contentWorld))
        super.add(scriptMessageHandler, contentWorld: contentWorld, name: name)
    }

    override func removeScriptMessageHandler(forName name: String, contentWorld: WKContentWorld) {
        removedHandlers.append((name, contentWorld))
        super.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}

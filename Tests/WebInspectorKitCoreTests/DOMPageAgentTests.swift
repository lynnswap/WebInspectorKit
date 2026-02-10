import Testing
import WebKit
@testable import WebInspectorKitCore

@MainActor
struct DOMSessionTests {
    @Test
    func detachClearsSelection() {
        let session = DOMSession(configuration: .init(snapshotDepth: 3, subtreeDepth: 2))
        session.selection.nodeId = 42
        session.selection.preview = "<div>"
        session.selection.attributes = [DOMAttribute(nodeId: 42, name: "class", value: "title")]
        session.selection.path = ["html", "body", "div"]
        session.selection.selectorPath = "#title"

        session.detach()

        #expect(session.selection.nodeId == nil)
        #expect(session.selection.preview.isEmpty)
        #expect(session.selection.attributes.isEmpty)
        #expect(session.selection.path.isEmpty)
        #expect(session.selection.selectorPath.isEmpty)
    }

    @Test
    func beginSelectionModeWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init())
        do {
            _ = try await session.beginSelectionMode()
            #expect(Bool(false))
        } catch let error as WebInspectorCoreError {
            guard case .scriptUnavailable = error else {
                #expect(Bool(false))
                return
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func captureSnapshotWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init(snapshotDepth: 2))
        do {
            _ = try await session.captureSnapshot(maxDepth: 2)
            #expect(Bool(false))
        } catch let error as WebInspectorCoreError {
            guard case .scriptUnavailable = error else {
                #expect(Bool(false))
                return
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func selectionCopyTextWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init())
        do {
            _ = try await session.selectionCopyText(nodeId: 1, kind: .html)
            #expect(Bool(false))
        } catch let error as WebInspectorCoreError {
            guard case .scriptUnavailable = error else {
                #expect(Bool(false))
                return
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func attachRegistersHandlersAndInstallsUserScripts() {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()

        session.attach(to: webView)

        let addedHandlerNames = controller.addedHandlers.map(\.name)
        #expect(addedHandlerNames.contains("webInspectorDOMSnapshot"))
        #expect(addedHandlerNames.contains("webInspectorDOMMutations"))
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.contains { $0.source.contains("webInspectorDOM") })
    }

    @Test
    func suspendRemovesHandlersAndClearsWebView() {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()

        session.attach(to: webView)
        let removedBefore = controller.removedHandlers.count

        session.suspend()

        let removedHandlerNames = controller.removedHandlers.map(\.name)
        #expect(controller.removedHandlers.count > removedBefore)
        #expect(removedHandlerNames.contains("webInspectorDOMSnapshot"))
        #expect(removedHandlerNames.contains("webInspectorDOMMutations"))
        #expect(session.pageWebView == nil)
    }

    @Test
    func attachInstallsInspectorScriptIntoPage() async throws {
        let session = DOMSession(configuration: .init())
        let (webView, _) = makeTestWebView()

        session.attach(to: webView)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)

        let raw = try await webView.evaluateJavaScript(
            "(() => Boolean(window.webInspectorDOM && window.webInspectorDOM.__installed))();",
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

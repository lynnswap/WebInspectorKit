import Testing
import WebKit
import WebInspectorEngine
@testable import WebInspectorUI
@testable import WebInspectorRuntime

@MainActor


struct DOMInspectorTests {
    @Test
    func exposesSelectedItemFromSessionGraphStore() {
        let controller = WIModel()
        let inspector = controller.dom
        #expect(inspector.selectedEntry == nil)
        #expect(inspector.session.graphStore.selectedEntry == nil)
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() {
        let controller = WIModel()
        let inspector = controller.dom
        let webView = makeTestWebView()

        #expect(inspector.hasPageWebView == false)
        inspector.attach(to: webView)
        #expect(inspector.hasPageWebView == true)
        #expect(inspector.session.lastPageWebView === webView)

        inspector.detach()
        #expect(inspector.hasPageWebView == false)
        #expect(inspector.session.lastPageWebView == nil)
        #expect(inspector.selectedEntry == nil)
    }

    @Test
    func attachSwitchingPageClearsPendingMutationBundles() {
        let controller = WIModel()
        let inspector = controller.dom
        let firstWebView = makeTestWebView()
        let secondWebView = makeTestWebView()

        inspector.attach(to: firstWebView)
        inspector.enqueueMutationBundle("{\"kind\":\"test\"}", preserveState: true)
        #expect(inspector.pendingMutationBundleCount == 1)

        inspector.attach(to: secondWebView)

        #expect(inspector.session.lastPageWebView === secondWebView)
        #expect(inspector.pendingMutationBundleCount == 0)
    }

    @Test
    func reloadInspectorWithoutPageSetsErrorMessage() async {
        let controller = WIModel()
        let inspector = controller.dom
        #expect(inspector.errorMessage == nil)

        await inspector.reloadInspector()

        #expect(inspector.errorMessage == "Web view unavailable.")
    }

    @Test
    func updateSnapshotDepthClampsAndUpdatesConfiguration() {
        let controller = WIModel()
        let inspector = controller.dom
        inspector.updateSnapshotDepth(0)
        #expect(inspector.session.configuration.snapshotDepth == 1)

        inspector.updateSnapshotDepth(6)
        #expect(inspector.session.configuration.snapshotDepth == 6)
    }

    @Test
    func updateAndRemoveAttributeMutateSelectionState() {
        let controller = WIModel()
        let inspector = controller.dom
        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                localID: 7,
                preview: "<div id=\"foo\">",
                attributes: [
                    DOMAttribute(nodeId: 7, name: "class", value: "old"),
                    DOMAttribute(nodeId: 7, name: "id", value: "foo"),
                ],
                path: [],
                selectorPath: "#foo",
                styleRevision: 0
            )
        )

        inspector.updateAttributeValue(name: "class", value: "new")
        #expect(inspector.selectedEntry?.attributes.first(where: { $0.name == "class" })?.value == "new")

        inspector.removeAttribute(name: "id")
        #expect(inspector.selectedEntry?.attributes.contains(where: { $0.name == "id" }) == false)
    }

    @Test
    func detachClearsErrorMessage() async {
        let controller = WIModel()
        let inspector = controller.dom
        await inspector.reloadInspector()
        #expect(inspector.errorMessage != nil)

        inspector.detach()

        #expect(inspector.errorMessage == nil)
    }

    @Test
    func detachClearsMatchedStylesState() {
        let controller = WIModel()
        let inspector = controller.dom
        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                localID: 11,
                preview: "<div class=\"target\">",
                attributes: [],
                path: [],
                selectorPath: ".target",
                styleRevision: 0
            )
        )
        inspector.session.graphStore.applyMatchedStyles(
            .init(
                nodeId: 11,
                rules: [
                    DOMMatchedStyleRule(
                        origin: .author,
                        selectorText: ".target",
                        declarations: [DOMMatchedStyleDeclaration(name: "color", value: "red", important: false)],
                        sourceLabel: "inline"
                    ),
                ],
                truncated: true,
                blockedStylesheetCount: 3
            ),
            for: 11
        )
        inspector.session.graphStore.beginMatchedStylesLoading(for: 11)

        inspector.detach()

        #expect(inspector.selectedEntry == nil)
        #expect(inspector.session.graphStore.entriesByID.isEmpty)
    }

    @Test
    func deletingTwoNodesThenUndoTwiceRestoresBothNodes() async throws {
        let controller = WIModel()
        let inspector = controller.dom
        let webView = makeTestWebView()
        let undoManager = UndoManager()
        let html = """
        <html>
            <body>
                <div id="first">First</div>
                <div id="second">Second</div>
            </body>
        </html>
        """

        inspector.attach(to: webView)
        await loadHTML(html, in: webView)

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let firstNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "first"),
              let secondNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "second")
        else {
            Issue.record("target nodes were not found in snapshot")
            return
        }

        inspector.deleteNode(nodeId: firstNodeID, undoManager: undoManager)
        inspector.deleteNode(nodeId: secondNodeID, undoManager: undoManager)

        let bothDeleted = await waitForCondition {
            let firstExists = await domNodeExists(withID: "first", in: webView)
            let secondExists = await domNodeExists(withID: "second", in: webView)
            return !firstExists && !secondExists
        }
        #expect(bothDeleted == true)

        undoManager.undo()
        let secondRestored = await waitForCondition {
            await domNodeExists(withID: "second", in: webView)
        }
        #expect(secondRestored == true)
        #expect(await domNodeExists(withID: "first", in: webView) == false)

        undoManager.undo()
        let firstRestored = await waitForCondition {
            await domNodeExists(withID: "first", in: webView)
        }
        #expect(firstRestored == true)
        #expect(await domNodeExists(withID: "second", in: webView) == true)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func waitForCondition(
        maxAttempts: Int = 250,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxAttempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    private func domNodeExists(withID id: String, in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return document.getElementById(identifier) !== null;",
            arguments: ["identifier": id],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func findNodeId(
        inSnapshotJSON snapshotJSON: String,
        attributeName: String,
        attributeValue: String
    ) -> Int? {
        guard
            let data = snapshotJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let root = object["root"] as? [String: Any]
        else {
            return nil
        }
        return findNodeId(inNode: root, attributeName: attributeName, attributeValue: attributeValue)
    }

    private func findNodeId(
        inNode node: [String: Any],
        attributeName: String,
        attributeValue: String
    ) -> Int? {
        if let attributes = node["attributes"] as? [String] {
            var index = 0
            while index + 1 < attributes.count {
                if attributes[index] == attributeName, attributes[index + 1] == attributeValue {
                    return node["nodeId"] as? Int
                }
                index += 2
            }
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                if let nodeID = findNodeId(inNode: child, attributeName: attributeName, attributeValue: attributeValue) {
                    return nodeID
                }
            }
        }
        return nil
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

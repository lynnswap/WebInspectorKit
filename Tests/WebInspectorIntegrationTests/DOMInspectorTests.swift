import Testing
import WebKit
@testable import WebInspectorCore
@testable import WebInspectorDOM
@testable import WebInspectorNetwork
@testable import WebInspectorShell
@testable import WebInspectorTransport

@MainActor
struct DOMInspectorTests {
    @Test
    func exposesSelectedItemFromSessionGraphStore() {
        let controller = WIInspectorController()
        let inspector = controller.dom
        #expect(inspector.selectedEntry == nil)
        #expect(inspector.session.graphStore.selectedEntry == nil)
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() {
        let controller = WIInspectorController()
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
        #expect(inspector.treeRows.isEmpty)
    }

    @Test
    func reloadInspectorWithoutPageSetsErrorMessage() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        #expect(inspector.errorMessage == nil)

        await inspector.reloadInspector()

        #expect(inspector.errorMessage == "Web view unavailable.")
    }

    @Test
    func updateAndRemoveAttributeMutateSelectionState() {
        let controller = WIInspectorController()
        let inspector = controller.dom
        inspector.session.graphStore.applySnapshot(
            .init(
                root: DOMGraphNodeDescriptor(
                    nodeID: 7,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                )
            )
        )
        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                nodeID: 7,
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
    func detachClearsErrorMessageAndGraphState() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        inspector.attach(to: webView)
        await loadHTML(
            """
            <html><body><main><div id="target">Hello</div></main></body></html>
            """,
            in: webView
        )
        await inspector.reloadInspector()
        let loaded = await waitForCondition {
            inspector.treeRows.isEmpty == false
        }
        #expect(loaded == true)

        guard let selectedNodeID = inspector.session.graphStore.rootID?.nodeID else {
            Issue.record("expected a loaded DOM root before mutating selection state")
            return
        }

        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                nodeID: selectedNodeID,
                preview: "<div class=\"target\">",
                attributes: [],
                path: [],
                selectorPath: ".target",
                styleRevision: 0
            )
        )
        inspector.session.graphStore.applyMatchedStyles(
            .init(
                nodeId: selectedNodeID,
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
            for: selectedNodeID
        )
        inspector.session.graphStore.beginMatchedStylesLoading(for: selectedNodeID)

        inspector.detach()

        #expect(inspector.errorMessage == nil)
        #expect(inspector.selectedEntry == nil)
        #expect(inspector.session.graphStore.entriesByID.isEmpty)
        #expect(inspector.treeRows.isEmpty)
    }

    @Test
    func reloadInspectorLoadsTreeRowsForAttachedPage() async {
        let controller = makeTransportController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        inspector.attach(to: webView)
        await loadHTML(
            """
            <html>
                <body>
                    <main id="content">
                        <section><h1>Hello</h1><p>World</p></section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )

        await inspector.reloadInspector()

        let loaded = await waitForCondition {
            inspector.treeRows.isEmpty == false && inspector.session.graphStore.rootID != nil
        }
        #expect(loaded == true)
        #expect(inspector.treeRows.count > 0)
        #expect(inspector.transportSupportSnapshot != nil)
    }

    @Test
    func reloadInspectorLoadsTreeRowsWhenTransportIsUnsupported() async {
        let controller = WIInspectorController(
            domSession: DOMSession(
                configuration: .init(),
                defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
            ),
            networkSession: NetworkSession(
                configuration: .init(),
                defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
            )
        )
        let inspector = controller.dom
        let webView = makeTestWebView()

        inspector.attach(to: webView)
        await loadHTML(
            """
            <html>
                <body>
                    <main id="legacy-content">
                        <section><h1>Hello</h1><p>Legacy</p></section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )

        await inspector.reloadInspector()

        let loaded = await waitForCondition {
            inspector.treeRows.isEmpty == false && inspector.session.graphStore.rootID != nil
        }
        #expect(loaded == true)
        #expect(inspector.transportSupportSnapshot?.isSupported == false)
        #expect(inspector.treeRows.count > 0)
    }

    @Test
    func selectingEntryLoadsMatchedStylesViaTransportWithoutProtocolEnable() async {
        let controller = makeTransportController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        inspector.attach(to: webView)
        await loadHTML(
            """
            <html>
                <head>
                    <style>
                        #content {
                            color: rgb(255, 0, 0);
                            display: block;
                        }
                    </style>
                </head>
                <body>
                    <main id="content">Hello</main>
                </body>
            </html>
            """,
            in: webView
        )

        let snapshot = try? await withTimeout(.seconds(10), description: "captureSnapshot for matched styles") {
            try await inspector.session.captureSnapshot(maxDepth: 5)
        }
        guard let snapshot,
              let contentNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "content") else {
            Issue.record("target node was not found in transport snapshot")
            return
        }

        do {
            let payload = try await withTimeout(.seconds(10), description: "matchedStyles for #content") {
                try await inspector.session.matchedStyles(nodeId: contentNodeID, maxRules: 0)
            }
            #expect(payload.rules.contains(where: { $0.selectorText.contains("#content") }))
            #expect(inspector.errorMessage == nil)
        } catch {
            Issue.record("matched styles transport fetch failed: \(error.localizedDescription)")
        }
    }

    @Test
    func deletingTwoNodesThenUndoTwiceRestoresBothNodes() async throws {
        let controller = makeTransportController()
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
        await inspector.reloadInspector()

        let snapshot = try await withTimeout(.seconds(10), description: "captureSnapshot") {
            try await inspector.session.captureSnapshot(maxDepth: 5)
        }
        guard let firstNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "first"),
              let secondNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "second")
        else {
            Issue.record("target nodes were not found in snapshot")
            return
        }

        inspector.deleteNode(nodeId: firstNodeID, undoManager: undoManager)
        let firstDeleted = await waitForCondition {
            await domNodeExists(withID: "first", in: webView) == false
        }
        #expect(firstDeleted == true)

        inspector.deleteNode(nodeId: secondNodeID, undoManager: undoManager)
        let secondDeleted = await waitForCondition {
            await domNodeExists(withID: "second", in: webView) == false
        }
        #expect(secondDeleted == true)

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

    private func makeTransportController() -> WIInspectorController {
        WIInspectorController(
            domSession: DOMSession(configuration: .init()),
            networkSession: NetworkSession(bodyFetcher: NoopBodyFetcher())
        )
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            navigationDelegate.timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                navigationDelegate.resumeIfNeeded()
            }
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

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        description: String,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError(description: description)
            }

            let value = try await group.next()
            group.cancelAll()
            guard let value else {
                throw TimeoutError(description: description)
            }
            return value
        }
    }

    private func domNodeExists(withID id: String, in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return document.getElementById(identifier) !== null;",
            arguments: ["identifier": id],
            in: nil,
            contentWorld: .page
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

private func unsupportedTransportSnapshot() -> WITransportSupportSnapshot {
    WITransportSupportSnapshot(
        availability: .unsupported,
        backendKind: .unsupported,
        capabilities: [],
        failureReason: "unsupported for test"
    )
}

private struct TimeoutError: Error, LocalizedError {
    let description: String

    var errorDescription: String? {
        "Timed out while waiting for \(description)."
    }
}

@MainActor
private final class NoopBodyFetcher: NetworkBodyFetching {
    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBodyFetchResult {
        _ = ref
        _ = handle
        _ = role
        return .agentUnavailable
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resumeIfNeeded()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resumeIfNeeded()
    }

    func resumeIfNeeded() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume()
        continuation = nil
    }
}

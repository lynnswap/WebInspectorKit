import Testing
import WebInspectorTestSupport
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
        let treeRowsLoaded = treeRowsLoadedRecorder(for: inspector)

        inspector.attach(to: webView)
        await loadHTML(
            """
            <html><body><main><div id="target">Hello</div></main></body></html>
            """,
            in: webView
        )
        await inspector.reloadInspector()
        _ = await treeRowsLoaded.next(where: { $0 })

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
        let treeRowsLoaded = treeRowsLoadedRecorder(for: inspector)

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

        _ = await treeRowsLoaded.next(where: { $0 })
        #expect(inspector.treeRows.count > 0)
        #expect(inspector.session.graphStore.rootID != nil)
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
        let treeRowsLoaded = treeRowsLoadedRecorder(for: inspector)

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

        _ = await treeRowsLoaded.next(where: { $0 })
        #expect(inspector.transportSupportSnapshot?.isSupported == false)
        #expect(inspector.treeRows.count > 0)
        #expect(inspector.session.graphStore.rootID != nil)
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

        let snapshot = try? await inspector.session.captureSnapshot(maxDepth: 5)
        guard let snapshot,
              let contentNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "content") else {
            Issue.record("target node was not found in transport snapshot")
            return
        }

        do {
            let payload = try await inspector.session.matchedStyles(nodeId: contentNodeID, maxRules: 0)
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
        let deleteEvents = AsyncValueQueue<WIDOMInspectorStore.DeleteMutationEvent>()
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
        inspector.onDeleteMutationForTesting = { event in
            Task {
                await deleteEvents.push(event)
            }
        }

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let firstNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "first"),
              let secondNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "second")
        else {
            Issue.record("target nodes were not found in snapshot")
            return
        }

        inspector.deleteNode(nodeId: firstNodeID, undoManager: undoManager)
        let firstDelete = await deleteEvents.next()
        #expect(firstDelete == .removed(nodeId: firstNodeID))
        #expect(await domNodeExists(withID: "first", in: webView) == false)

        inspector.deleteNode(nodeId: secondNodeID, undoManager: undoManager)
        let secondDelete = await deleteEvents.next()
        #expect(secondDelete == .removed(nodeId: secondNodeID))
        #expect(await domNodeExists(withID: "second", in: webView) == false)

        undoManager.undo()
        let secondRestore = await deleteEvents.next()
        #expect(secondRestore == .restored(nodeId: secondNodeID))
        #expect(await domNodeExists(withID: "second", in: webView))
        #expect(await domNodeExists(withID: "first", in: webView) == false)

        undoManager.undo()
        let firstRestore = await deleteEvents.next()
        #expect(firstRestore == .restored(nodeId: firstNodeID))
        #expect(await domNodeExists(withID: "first", in: webView))
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
            webView.loadHTMLString(html, baseURL: nil)
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

@MainActor
private func treeRowsLoadedRecorder(
    for inspector: WIDOMInspectorStore
) -> ObservationRecorder<Bool> {
    let recorder = ObservationRecorder<Bool>()
    recorder.record { didChange in
        inspector.observe(\.graphProjectionRevision, options: [.removeDuplicates]) { _ in
            didChange(inspector.treeRows.isEmpty == false && inspector.session.graphStore.rootID != nil)
        }
    }
    return recorder
}


private func unsupportedTransportSnapshot() -> WITransportSupportSnapshot {
    WITransportSupportSnapshot(
        availability: .unsupported,
        backendKind: .unsupported,
        capabilities: [],
        failureReason: "unsupported for test"
    )
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
        continuation?.resume()
        continuation = nil
    }
}

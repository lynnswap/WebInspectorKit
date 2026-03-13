import Testing
import WebInspectorKit
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorCore
@testable import WebInspectorTransport
@testable import WebInspectorUI

@MainActor
@Suite(.serialized, .webKitIsolated)
struct DOMInspectorTests {
    @Test
    func exposesSelectedItemFromSessionGraphStore() {
        let controller = WISessionController()
        let store = controller.domStore
        #expect(store.selectedEntry == nil)
        #expect(store.session.graphStore.selectedEntry == nil)
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() {
        let controller = WISessionController()
        let store = controller.domStore
        let webView = makeTestWebView()

        #expect(store.hasPageWebView == false)
        store.attach(to: webView)
        #expect(store.hasPageWebView == true)
        #expect(store.session.lastPageWebView === webView)

        store.detach()
        #expect(store.hasPageWebView == false)
        #expect(store.session.lastPageWebView == nil)
        #expect(store.selectedEntry == nil)
        #expect(store.treeRows.isEmpty)
    }

    @Test
    func reloadInspectorWithoutPageSetsErrorMessage() async {
        let controller = WISessionController()
        let store = controller.domStore
        #expect(store.errorMessage == nil)

        await store.reloadFrontend()

        #expect(store.errorMessage == "Web view unavailable.")
    }

    @Test
    func updateAndRemoveAttributeMutateSelectionState() {
        let controller = WISessionController()
        let store = controller.domStore
        store.session.graphStore.applySnapshot(
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
        store.session.graphStore.applySelectionSnapshot(
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

        store.updateAttributeValue(name: "class", value: "new")
        #expect(store.selectedEntry?.attributes.first(where: { $0.name == "class" })?.value == "new")

        store.removeAttribute(name: "id")
        #expect(store.selectedEntry?.attributes.contains(where: { $0.name == "id" }) == false)
    }

    @Test
    func detachClearsErrorMessageAndGraphState() async {
        await withWebKitTestIsolation {
            let controller = makeTransportController()
            let store = controller.domStore
            let webView = makeTestWebView()

            store.attach(to: webView)
            await loadHTML(
                """
                <html><body><main><div id="target">Hello</div></main></body></html>
                """,
                in: webView
            )
            await store.reloadFrontend()
            #expect(await waitForTreeRowsToLoad(in: store))

            guard let selectedNodeID = store.session.graphStore.rootID?.nodeID else {
                Issue.record("expected a loaded DOM root before mutating selection state")
                return
            }

            store.session.graphStore.applySelectionSnapshot(
                .init(
                    nodeID: selectedNodeID,
                    preview: "<div class=\"target\">",
                    attributes: [],
                    path: [],
                    selectorPath: ".target",
                    styleRevision: 0
                )
            )
            store.session.graphStore.applyStyle(
                .init(
                    nodeId: selectedNodeID,
                    matched: .init(
                        sections: [
                            .init(
                                kind: .element,
                                rules: [
                                    DOMStyleRule(
                                        origin: .author,
                                        selectorText: ".target",
                                        declarations: [
                                            DOMStyleDeclaration(
                                                name: "color",
                                                value: "red",
                                                important: false
                                            )
                                        ],
                                        source: .init(label: "inline")
                                    )
                                ]
                            )
                        ],
                        isTruncated: true,
                        blockedStylesheetCount: 3
                    ),
                    computed: .empty
                ),
                for: selectedNodeID
            )
            store.session.graphStore.beginStyleLoading(for: selectedNodeID)

            store.detach()

            #expect(store.errorMessage == nil)
            #expect(store.selectedEntry == nil)
            #expect(store.session.graphStore.entriesByID.isEmpty)
            #expect(store.treeRows.isEmpty)
        }
    }

    @Test
    func reloadInspectorLoadsTreeRowsForAttachedPage() async {
        await withWebKitTestIsolation {
            let controller = makeTransportController()
            let store = controller.domStore
            let webView = makeTestWebView()

            store.attach(to: webView)
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

            await store.reloadFrontend()

            #expect(await waitForTreeRowsToLoad(in: store))
            #expect(store.treeRows.count > 0)
            #expect(store.session.graphStore.rootID != nil)
            #expect(store.backendSupport.isSupported)
        }
    }

    @Test
    func reloadInspectorLoadsTreeRowsWhenTransportIsUnsupported() async {
        await withWebKitTestIsolation {
            let controller = WISessionController(
                domSession: WIDOMRuntime(
                    configuration: .init(),
                    defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
                ),
                networkSession: WINetworkRuntime(
                    configuration: .init(),
                    defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
                )
            )
            let store = controller.domStore
            let webView = makeTestWebView()

            store.attach(to: webView)
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

            await store.reloadFrontend()

            #expect(await waitForTreeRowsToLoad(in: store))
            #expect(store.backendSupport.isSupported)
            #expect(store.treeRows.count > 0)
            #expect(store.session.graphStore.rootID != nil)
        }
    }

    @Test
    func selectingEntryLoadsMatchedStylesViaTransportWithoutProtocolEnable() async {
        await withWebKitTestIsolation {
            let controller = makeTransportController()
            let store = controller.domStore
            let webView = makeTestWebView()

            store.attach(to: webView)
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

            await store.reloadFrontend()
            #expect(await waitForTreeRowsToLoad(in: store))

            guard let contentNodeID = findNodeId(
                in: store.session.graphStore,
                attributeName: "id",
                attributeValue: "content"
            ) else {
                Issue.record("target node was not found in graph store")
                return
            }

            do {
                let payload = try await store.session.styles(nodeId: contentNodeID, maxMatchedRules: 0)
                #expect(payload.matched.allRules.contains(where: { $0.selectorText.contains("#content") }))
                #expect(store.errorMessage == nil)
            } catch {
                Issue.record("matched styles transport fetch failed: \(error.localizedDescription)")
            }
        }
    }

    @Test
    func deletingTwoNodesThenUndoTwiceRestoresBothNodes() async {
        await withWebKitTestIsolation {
            let controller = makeLegacyController()
            let store = controller.domStore
            let webView = makeTestWebView()
            let undoManager = UndoManager()
            let deleteEvents = AsyncValueQueue<WIDOMStore.DeleteMutationEvent>()
            let html = """
            <html>
                <body>
                    <div id="first">First</div>
                    <div id="second">Second</div>
                </body>
            </html>
            """

            store.attach(to: webView)
            await loadHTML(html, in: webView)
            await store.reloadFrontend()
            #expect(await waitForTreeRowsToLoad(in: store))
            store.onDeleteMutationForTesting = { event in
                Task {
                    await deleteEvents.push(event)
                }
            }

            guard let firstNodeID = findNodeId(
                in: store.session.graphStore,
                attributeName: "id",
                attributeValue: "first"
            ),
            let secondNodeID = findNodeId(
                in: store.session.graphStore,
                attributeName: "id",
                attributeValue: "second"
            )
            else {
                Issue.record("target nodes were not found in graph store")
                return
            }

            store.deleteNode(nodeId: firstNodeID, undoManager: undoManager)
            let firstDelete = await deleteEvents.next()
            #expect(firstDelete == .removed(nodeId: firstNodeID))
            #expect(await domNodeExists(withID: "first", in: webView) == false)

            store.deleteNode(nodeId: secondNodeID, undoManager: undoManager)
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
    }

    private func makeTestWebView() -> WKWebView {
        makeIsolatedTestWebView()
    }

    private func makeTransportController() -> WISessionController {
        let domGraphStore = DOMGraphStore()
        let domBackend = WIBackendFactory.makeDOMBackend(
            configuration: .init(),
            graphStore: domGraphStore
        )
        let domRuntime = WIDOMRuntime(
            configuration: .init(),
            graphStore: domGraphStore,
            backend: domBackend
        )
        let domFrontendBridge = WIDOMFrontendRuntime(session: domRuntime)

        let networkRuntime = WINetworkRuntime(
            configuration: .init(),
            backend: WIBackendFactory.makeNetworkBackend(configuration: .init())
        )

        return WISessionController(
            domSession: domRuntime,
            networkSession: networkRuntime,
            domFrontendBridge: domFrontendBridge
        )
    }

    private func makeLegacyController() -> WISessionController {
        WISessionController(
            domSession: WIDOMRuntime(
                configuration: .init(),
                defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
            ),
            networkSession: WINetworkRuntime(
                configuration: .init(),
                defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
            )
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
        in graphStore: DOMGraphStore,
        attributeName: String,
        attributeValue: String
    ) -> Int? {
        graphStore.entriesByID.values.first(where: { entry in
            entry.attributes.contains(where: { attribute in
                attribute.name == attributeName && attribute.value == attributeValue
            })
        })?.id.nodeID
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
private func waitForTreeRowsToLoad(
    in store: WIDOMStore,
    maxTurns: Int = 8_192
) async -> Bool {
    if store.treeRows.isEmpty == false, store.session.graphStore.rootID != nil {
        return true
    }

    for _ in 0..<maxTurns {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        if store.treeRows.isEmpty == false, store.session.graphStore.rootID != nil {
            return true
        }
    }

    return store.treeRows.isEmpty == false && store.session.graphStore.rootID != nil
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
    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
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

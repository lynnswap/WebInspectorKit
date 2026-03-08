import Testing
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
struct WIDOMModelTests {
    @Test
    func attachBuildsNativeTreeRowsFromTransportSnapshot() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)

        let loaded = await waitUntil {
            inspector.treeRows.isEmpty == false
        }
        #expect(loaded == true)
        #expect(Array(inspector.treeRows.map(\.id.nodeID).prefix(2)) == [2, 3])
        #expect(inspector.treeRows.first?.depth == 0)
        #expect(inspector.expandedEntryIDs.contains(where: { $0.nodeID == 1 }))
    }

    @Test
    func togglingExpansionFetchesMissingChildrenOnce() async {
        let graphStore = DOMGraphStore()
        let rootSnapshot = DOMGraphSnapshot(root: makeExpandableDocumentTree())
        let childDescriptor = DOMGraphNodeDescriptor(
            nodeID: 5,
            nodeType: 1,
            nodeName: "SPAN",
            localName: "span",
            nodeValue: "",
            attributes: [],
            childCount: 0,
            layoutFlags: [],
            isRendered: true,
            children: []
        )
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: rootSnapshot,
            requestedChildren: [4: [childDescriptor]]
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let initialRowsLoaded = await waitUntil {
            inspector.treeRows.contains(where: { $0.id.nodeID == 4 })
        }
        #expect(initialRowsLoaded == true)

        let targetID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 4)
        inspector.toggleExpansion(of: targetID)

        let childLoaded = await waitUntil {
            inspector.treeRows.contains(where: { $0.id.nodeID == 5 })
        }
        #expect(childLoaded == true)
        #expect(driver.requestedParentNodeIDs == [4])

        inspector.toggleExpansion(of: targetID)
        inspector.toggleExpansion(of: targetID)

        let noRefetch = await waitUntil {
            driver.requestedParentNodeIDs.count == 1
        }
        #expect(noRefetch == true)
    }

    @Test
    func documentRootRowRemainsVisibleWhenTopLevelChildrenAreMissing() async {
        let graphStore = DOMGraphStore()
        let rootSnapshot = DOMGraphSnapshot(
            root: DOMGraphNodeDescriptor(
                nodeID: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                nodeValue: "",
                attributes: [],
                childCount: 2,
                layoutFlags: [],
                isRendered: true,
                children: [
                    DOMGraphNodeDescriptor(
                        nodeID: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        nodeValue: "",
                        attributes: [],
                        childCount: 0,
                        layoutFlags: [],
                        isRendered: true,
                        children: []
                    ),
                ]
            )
        )
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: rootSnapshot
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            inspector.treeRows.isEmpty == false
        }

        #expect(loaded == true)
        #expect(inspector.treeRows.first?.id.nodeID == 1)
    }

    @Test
    func selectEntryUpdatesSelectionAndHighlightState() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil
        }
        #expect(loaded == true)

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)
        await Task.yield()

        #expect(inspector.selectedEntry?.id == bodyID)
        #expect(driver.highlightedNodeIDs == [3])

        inspector.selectEntry(nil)
        await Task.yield()

        #expect(inspector.selectedEntry == nil)
        #expect(driver.hideHighlightCallCount == 1)
    }

    @Test
    func selectionModePersistsRequiredDepthIntoSessionConfiguration() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            selectionModeResult: .init(cancelled: false, requiredDepth: 12)
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        inspector.toggleSelectionMode()

        let updated = await waitUntil {
            session.configuration.snapshotDepth >= 13
                && driver.reloadRequestedDepths.contains(13)
        }

        #expect(updated == true)
        #expect(session.configuration.rootBootstrapDepth >= 13)
    }

    @Test
    func selectionSnapshotRefreshesMatchedStylesForSameSelectedNode() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil
        }
        #expect(loaded == true)

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)

        let initialRefresh = await waitUntil {
            driver.matchedStylesRequests == [3]
        }
        #expect(initialRefresh == true)

        graphStore.applySelectionSnapshot(
            .init(
                nodeID: 3,
                preview: "<body>",
                attributes: [],
                path: ["html", "body"],
                selectorPath: "html > body",
                styleRevision: 1
            )
        )

        let refreshed = await waitUntil {
            driver.matchedStylesRequests == [3, 3]
        }
        #expect(refreshed == true)
    }

    @Test
    func matchedStylesFailureDoesNotRetryForUnchangedSelection() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            matchedStylesError: StubDOMPageDriverError.missingNode
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil
        }
        #expect(loaded == true)

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)

        let failedOnce = await waitUntil {
            driver.matchedStylesRequests.count == 1 && inspector.errorMessage != nil
        }
        #expect(failedOnce == true)

        let retried = await waitUntil(timeoutNanoseconds: 300_000_000) {
            driver.matchedStylesRequests.count > 1
        }
        #expect(retried == false)
    }

    @Test
    func invalidatedMatchedStylesRefreshesAgainForSameSelectionKey() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil
        }
        #expect(loaded == true)

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)

        let initialRefresh = await waitUntil {
            driver.matchedStylesRequests == [3]
        }
        #expect(initialRefresh == true)

        graphStore.invalidateMatchedStyles(for: 3)

        let refreshed = await waitUntil {
            driver.matchedStylesRequests == [3, 3]
        }
        #expect(refreshed == true)
    }
}

@MainActor
private final class StubDOMPageDriver: DOMPageDriving {
    weak var eventSink: (any DOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?

    private let graphStore: DOMGraphStore
    private let rootSnapshot: DOMGraphSnapshot
    private let requestedChildren: [Int: [DOMGraphNodeDescriptor]]
    private let selectionModeResult: DOMSelectionModeResult
    private let matchedStylesError: (any Error)?

    private(set) var requestedParentNodeIDs: [Int] = []
    private(set) var highlightedNodeIDs: [Int] = []
    private(set) var hideHighlightCallCount = 0
    private(set) var reloadRequestedDepths: [Int] = []
    private(set) var matchedStylesRequests: [Int] = []

    init(
        graphStore: DOMGraphStore,
        rootSnapshot: DOMGraphSnapshot,
        requestedChildren: [Int: [DOMGraphNodeDescriptor]] = [:],
        selectionModeResult: DOMSelectionModeResult = .init(cancelled: true, requiredDepth: 0),
        matchedStylesError: (any Error)? = nil
    ) {
        self.graphStore = graphStore
        self.rootSnapshot = rootSnapshot
        self.requestedChildren = requestedChildren
        self.selectionModeResult = selectionModeResult
        self.matchedStylesError = matchedStylesError
    }

    func updateConfiguration(_ configuration: DOMConfiguration) {
        _ = configuration
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView() {
        webView = nil
    }

    func setAutoSnapshot(enabled: Bool) async {
        _ = enabled
    }

    func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws {
        reloadRequestedDepths.append(requestedDepth ?? 0)
        _ = requestedDepth
        if preserveState == false {
            graphStore.resetForDocumentUpdate()
        }
        graphStore.applySnapshot(rootSnapshot)
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        requestedParentNodeIDs.append(parentNodeId)
        let descriptors = requestedChildren[parentNodeId] ?? []
        if graphStore.entry(forNodeID: parentNodeId) != nil {
            graphStore.applyMutationBundle(
                .init(events: [
                    .setChildNodes(parentNodeID: parentNodeId, nodes: descriptors)
                ])
            )
        }
        return descriptors
    }

    func captureSnapshot(maxDepth: Int) async throws -> String {
        _ = maxDepth
        return "{}"
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        _ = nodeId
        _ = maxDepth
        return "{}"
    }

    func matchedStyles(nodeId: Int, maxRules: Int) async throws -> DOMMatchedStylesPayload {
        _ = maxRules
        matchedStylesRequests.append(nodeId)
        if let matchedStylesError {
            throw matchedStylesError
        }
        return DOMMatchedStylesPayload(nodeId: nodeId, rules: [], truncated: false, blockedStylesheetCount: 0)
    }

    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        _ = maxDepth
        return [:] as [String: Any]
    }

    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        _ = nodeId
        _ = maxDepth
        return [:] as [String: Any]
    }

    func beginSelectionMode() async throws -> DOMSelectionModeResult {
        selectionModeResult
    }

    func cancelSelectionMode() async {
    }

    func highlight(nodeId: Int) async {
        highlightedNodeIDs.append(nodeId)
    }

    func hideHighlight() async {
        hideHighlightCallCount += 1
    }

    func rememberPendingSelection(nodeId: Int?) {
        _ = nodeId
    }

    func removeNode(nodeId: Int) async {
        _ = nodeId
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        _ = nodeId
        return nil
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        _ = undoToken
        return false
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool {
        _ = undoToken
        _ = nodeId
        return false
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        _ = nodeId
        _ = name
        _ = value
    }

    func removeAttribute(nodeId: Int, name: String) async {
        _ = nodeId
        _ = name
    }

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        _ = nodeId
        _ = kind
        return ""
    }
}

private enum StubDOMPageDriverError: Error {
    case missingNode
}

private func makeDocumentTree() -> DOMGraphNodeDescriptor {
    DOMGraphNodeDescriptor(
        nodeID: 1,
        nodeType: 9,
        nodeName: "#document",
        localName: "",
        nodeValue: "",
        attributes: [],
        childCount: 1,
        layoutFlags: [],
        isRendered: true,
        children: [
            DOMGraphNodeDescriptor(
                nodeID: 2,
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                nodeValue: "",
                attributes: [],
                childCount: 1,
                layoutFlags: [],
                isRendered: true,
                children: [
                    DOMGraphNodeDescriptor(
                        nodeID: 3,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        nodeValue: "",
                        attributes: [],
                        childCount: 0,
                        layoutFlags: [],
                        isRendered: true,
                        children: []
                    )
                ]
            )
        ]
    )
}

private func makeExpandableDocumentTree() -> DOMGraphNodeDescriptor {
    DOMGraphNodeDescriptor(
        nodeID: 1,
        nodeType: 9,
        nodeName: "#document",
        localName: "",
        nodeValue: "",
        attributes: [],
        childCount: 1,
        layoutFlags: [],
        isRendered: true,
        children: [
            DOMGraphNodeDescriptor(
                nodeID: 2,
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                nodeValue: "",
                attributes: [],
                childCount: 1,
                layoutFlags: [],
                isRendered: true,
                children: [
                    DOMGraphNodeDescriptor(
                        nodeID: 3,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        nodeValue: "",
                        attributes: [],
                        childCount: 1,
                        layoutFlags: [],
                        isRendered: true,
                        children: [
                            DOMGraphNodeDescriptor(
                                nodeID: 4,
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                nodeValue: "",
                                attributes: [],
                                childCount: 1,
                                layoutFlags: [],
                                isRendered: true,
                                children: []
                            )
                        ]
                    )
                ]
            )
        ]
    )
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return condition()
}

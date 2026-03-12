import Testing
import WebKit
import ObservationBridge
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
@Suite(.serialized)
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

        graphStore.invalidateStyle(for: 3, reason: .manualRefresh)

        let refreshed = await waitUntil {
            driver.matchedStylesRequests == [3, 3]
        }
        #expect(refreshed == true)
    }

    @Test
    func rapidSelectionSnapshotBurstRefreshesMatchedStylesForLatestRevision() async {
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
                && driver.matchedStylesRequestRevisions.isEmpty == false
        }
        #expect(initialRefresh == true)

        for revision in 1...3 {
            graphStore.applySelectionSnapshot(
                .init(
                    nodeID: 3,
                    preview: "<body data-revision=\"\(revision)\">",
                    attributes: [],
                    path: ["html", "body"],
                    selectorPath: "html > body.revision-\(revision)",
                    styleRevision: revision
                )
            )
        }

        let refreshed = await waitUntil {
            driver.matchedStylesRequests.count >= 2
                && driver.matchedStylesRequestRevisions.last == 3
        }
        #expect(refreshed == true)
        #expect(driver.matchedStylesRequestRevisions.contains(1) == false)
        #expect(driver.matchedStylesRequestRevisions.contains(2) == false)
    }

    @Test
    func observingSelectedEntryPublishesFrontendSelectionChanges() async {
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
        var observationHandles = Set<ObservationHandle>()
        var observedNodeIDs: [Int?] = []

        inspector.observe(\.selectedEntry, options: [.removeDuplicates]) { selected in
            observedNodeIDs.append(selected?.id.nodeID)
        }
        .store(in: &observationHandles)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil
        }
        #expect(loaded == true)

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

        let published = await waitUntil {
            observedNodeIDs.contains(3)
        }
        #expect(published == true)
        #expect(inspector.selectedEntry?.id.nodeID == 3)
    }

    @Test
    func frontendSelectionMessagePublishesInspectorSelectedEntry() async {
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
        var observationHandles = Set<ObservationHandle>()
        var observedNodeIDs: [Int?] = []

        inspector.observe(\.selectedEntry, options: [.removeDuplicates]) { selected in
            observedNodeIDs.append(selected?.id.nodeID)
        }
        .store(in: &observationHandles)

        inspector.attach(to: webView)
        let loaded = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil
        }
        #expect(loaded == true)

        inspector.withFrontendStore { store in
            store.testHandleDOMSelectionMessage([
                "nodeId": 3,
                "preview": "<body>",
                "attributes": [],
                "path": ["html", "body"],
                "selectorPath": "html > body",
                "styleRevision": 1
            ])
        }

        let published = await waitUntil {
            observedNodeIDs.contains(3)
        }
        #expect(published == true)
        #expect(inspector.selectedEntry?.selectorPath == "html > body")
    }

    @Test
    func frontendSelectionMissReloadsDocumentAndRestoresSelectedEntry() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            reloadSnapshots: [
                .init(root: makeDocumentTree()),
                .init(root: makeRecoveryDocumentTree())
            ]
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMModel(session: session)
        let webView = WKWebView(frame: .zero)

        inspector.attach(to: webView)
        let initialLoad = await waitUntil {
            graphStore.entry(forNodeID: 3) != nil && graphStore.entry(forNodeID: 6) == nil
        }
        #expect(initialLoad == true)

        inspector.withFrontendStore { store in
            store.testHandleDOMSelectionMessage([
                "nodeId": 6,
                "preview": "<div id=\"target\">",
                "attributes": [
                    ["name": "id", "value": "target"],
                ],
                "path": ["html", "body", "main", "div"],
                "selectorPath": "#target",
                "styleRevision": 1
            ])
        }

        let recovered = await waitUntil {
            inspector.selectedEntry?.id.nodeID == 6
        }
        #expect(recovered == true)
        #expect(driver.reloadRequestedDepths == [4, 8])
        #expect(inspector.selectedEntry?.selectorPath == "#target")
        #expect(inspector.selectedEntry?.attributes.contains(where: { $0.name == "id" && $0.value == "target" }) == true)
    }

    @Test
    func repeatedProgrammaticSelectionDoesNotBlockSubsequentObservedSelectionRefresh() async {
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
            graphStore.entry(forNodeID: 3) != nil && graphStore.entry(forNodeID: 2) != nil
        }
        #expect(loaded == true)

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)

        let initialRefresh = await waitUntil {
            driver.matchedStylesRequests.last == 3
        }
        #expect(initialRefresh == true)

        inspector.selectEntry(bodyID)

        graphStore.applySelectionSnapshot(
            .init(
                nodeID: 2,
                preview: "<html>",
                attributes: [],
                path: ["html"],
                selectorPath: "html",
                styleRevision: 1
            )
        )

        let observedRefresh = await waitUntil {
            driver.matchedStylesRequests.last == 2
        }
        #expect(observedRefresh == true)
    }

    @Test
    func staleProgrammaticSelectionDoesNotSuppressNextObservedSelectionRefresh() async {
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

        let staleID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 999)
        inspector.selectEntry(staleID)

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
            driver.matchedStylesRequests.last == 3
        }
        #expect(refreshed == true)
    }

    @Test
    func rapidFrontendSelectionMissesRecoverLatestRequestedNode() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            reloadSnapshots: [
                .init(root: makeDocumentTree()),
                .init(root: makeRecoveryDocumentTree(nodeID: 6, idValue: "first-target")),
                .init(root: makeRecoveryDocumentTree(nodeID: 7, idValue: "second-target"))
            ],
            reloadDelayNanoseconds: 50_000_000
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

        inspector.withFrontendStore { store in
            store.testHandleDOMSelectionMessage([
                "nodeId": 6,
                "preview": "<div id=\"first-target\">",
                "attributes": [
                    ["name": "id", "value": "first-target"],
                ],
                "path": ["html", "body", "main", "div"],
                "selectorPath": "#first-target",
                "styleRevision": 1
            ])
            store.testHandleDOMSelectionMessage([
                "nodeId": 7,
                "preview": "<div id=\"second-target\">",
                "attributes": [
                    ["name": "id", "value": "second-target"],
                ],
                "path": ["html", "body", "main", "div"],
                "selectorPath": "#second-target",
                "styleRevision": 2
            ])
        }

        let recovered = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            inspector.selectedEntry?.id.nodeID == 7
                && inspector.selectedEntry?.selectorPath == "#second-target"
                && inspector.selectedEntry?.attributes.contains(where: { $0.name == "id" && $0.value == "second-target" }) == true
        }
        #expect(recovered == true)
    }
}

@MainActor
private final class StubDOMPageDriver: DOMPageDriving {
    weak var eventSink: (any DOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?

    private let graphStore: DOMGraphStore
    private let reloadSnapshots: [DOMGraphSnapshot]
    private let requestedChildren: [Int: [DOMGraphNodeDescriptor]]
    private let selectionModeResult: DOMSelectionModeResult
    private let matchedStylesError: (any Error)?
    private var pendingSelectedNodeID: Int?
    private let reloadDelayNanoseconds: UInt64

    private(set) var requestedParentNodeIDs: [Int] = []
    private(set) var highlightedNodeIDs: [Int] = []
    private(set) var hideHighlightCallCount = 0
    private(set) var reloadRequestedDepths: [Int] = []
    private(set) var matchedStylesRequests: [Int] = []
    private(set) var matchedStylesRequestRevisions: [Int] = []

    init(
        graphStore: DOMGraphStore,
        rootSnapshot: DOMGraphSnapshot,
        reloadSnapshots: [DOMGraphSnapshot]? = nil,
        requestedChildren: [Int: [DOMGraphNodeDescriptor]] = [:],
        selectionModeResult: DOMSelectionModeResult = .init(cancelled: true, requiredDepth: 0),
        matchedStylesError: (any Error)? = nil,
        reloadDelayNanoseconds: UInt64 = 0
    ) {
        self.graphStore = graphStore
        self.reloadSnapshots = reloadSnapshots ?? [rootSnapshot]
        self.requestedChildren = requestedChildren
        self.selectionModeResult = selectionModeResult
        self.matchedStylesError = matchedStylesError
        self.reloadDelayNanoseconds = reloadDelayNanoseconds
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
        if reloadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: reloadDelayNanoseconds)
        }
        let snapshot = reloadSnapshots[min(reloadRequestedDepths.count - 1, reloadSnapshots.count - 1)]
        if preserveState == false {
            graphStore.resetForDocumentUpdate()
        }
        let resolvedSnapshot: DOMGraphSnapshot
        if preserveState,
           let pendingSelectedNodeID,
           snapshot.selectedNodeID == nil {
            resolvedSnapshot = .init(root: snapshot.root, selectedNodeID: pendingSelectedNodeID)
        } else {
            resolvedSnapshot = snapshot
        }
        graphStore.applySnapshot(resolvedSnapshot)
        if graphStore.selectedEntry?.id.nodeID == pendingSelectedNodeID {
            self.pendingSelectedNodeID = nil
        }
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

    func styles(nodeId: Int, maxMatchedRules: Int) async throws -> DOMNodeStylePayload {
        _ = maxMatchedRules
        matchedStylesRequests.append(nodeId)
        matchedStylesRequestRevisions.append(graphStore.selectedEntry?.style.sourceRevision ?? -1)
        if let matchedStylesError {
            throw matchedStylesError
        }
        return DOMNodeStylePayload(nodeId: nodeId, matched: .empty, computed: .empty)
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
        return selectionModeResult
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
        pendingSelectedNodeID = nodeId
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

private func makeRecoveryDocumentTree(
    nodeID: Int = 6,
    idValue: String = "target"
) -> DOMGraphNodeDescriptor {
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
                                nodeID: 5,
                                nodeType: 1,
                                nodeName: "MAIN",
                                localName: "main",
                                nodeValue: "",
                                attributes: [],
                                childCount: 1,
                                layoutFlags: [],
                                isRendered: true,
                                children: [
                                    DOMGraphNodeDescriptor(
                                        nodeID: nodeID,
                                        nodeType: 1,
                                        nodeName: "DIV",
                                        localName: "div",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(nodeId: nodeID, name: "id", value: idValue)],
                                        childCount: 0,
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

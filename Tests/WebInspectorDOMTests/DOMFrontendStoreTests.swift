import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorUI
@testable import WebInspectorCore

@MainActor
@Suite(.serialized, .webKitIsolated)
struct DOMFrontendStoreTests {
    @Test
    func frontendSelectionMessageOnlyUpdatesSelectionSnapshot() {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        store.testHandleDOMSelectionMessage([
            "nodeId": 3,
            "preview": "<body>",
            "attributes": [],
            "path": ["html", "body"],
            "selectorPath": "html > body",
            "styleRevision": 1
        ])

        #expect(graphStore.selectedEntry?.id.nodeID == 3)
        #expect(graphStore.selectedEntry?.style.isLoading == false)
        #expect(graphStore.selectedEntry?.style.matched.isEmpty == true)
    }

    @Test
    func preparingForFrontendReloadResetsReadyAndQueuesDocumentRefresh() throws {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        store.testSetReady(true)
        store.testPrepareForFrontendReloadIfNeeded()

        let pendingRequest = try #require(store.testPendingDocumentRequest)
        #expect(store.testIsReady == false)
        #expect(pendingRequest.depth == session.configuration.fullReloadDepth)
        #expect(pendingRequest.preserveState == true)
    }

    @Test
    func readyMessageDoesNotBootstrapFrontendDocumentWhenAuthoritativeGraphIsEmpty() async {
        let graphStore = DOMGraphStore()
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let pageWebView = makeIsolatedTestWebView()
        _ = session.attach(to: pageWebView)

        let store = WIDOMFrontendRuntime(session: session)
        _ = store.makeInspectorWebView()
        let readyMessageProcessed = AsyncGate()
        store.onReadyMessageProcessedForTesting = {
            Task {
                await readyMessageProcessed.open()
            }
        }

        store.testHandleReadyMessage()
        await readyMessageProcessed.wait()

        #expect(store.testRequestedDocuments.isEmpty)
    }

    @Test
    func frontendDocumentBootstrapUsesAuthoritativeGraphSnapshotWhenGraphIsLoaded() throws {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTreeWithMissingBodyChildren()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )

        let store = WIDOMFrontendRuntime(session: session)
        let response = try #require(
            store.testImmediateFrontendResponseIfPossible(
                id: 71,
                method: "DOM.getDocument",
                nodeID: nil,
                documentGeneration: graphStore.documentGeneration
            )
        )
        let result = try #require(response["result"] as? [String: Any])
        let root = try #require(result["root"] as? [String: Any])
        let html = try #require((root["children"] as? [[String: Any]])?.first)
        let body = try #require((html["children"] as? [[String: Any]])?.first)

        #expect(response["id"] as? Int == 71)
        #expect(body["nodeId"] as? Int == 3)
        #expect(body["childNodeCount"] as? Int == 1)
        #expect((body["children"] as? [[String: Any]])?.isEmpty != false)
    }

    @Test
    func immediateFrontendDocumentResponseIsDisabledForStaleGeneration() {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))
        let staleGeneration = graphStore.documentGeneration
        graphStore.resetForDocumentUpdate()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )

        let store = WIDOMFrontendRuntime(session: session)
        let response = store.testImmediateFrontendResponseIfPossible(
            id: 72,
            method: "DOM.getDocument",
            nodeID: nil,
            documentGeneration: staleGeneration
        )

        #expect(response == nil)
    }

    @Test
    func staleGetDocumentResponseReturnsCurrentSnapshot() throws {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))
        let previousGeneration = graphStore.documentGeneration
        graphStore.resetForDocumentUpdate()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        let staleResponse = try #require(
            store.testStaleProtocolResponseIfNeeded(
                id: 91,
                method: "DOM.getDocument",
                nodeID: nil,
                documentGeneration: previousGeneration
            )
        )
        let result = try #require(staleResponse["result"] as? [String: Any])
        let root = try #require(result["root"] as? [String: Any])

        #expect(root["nodeId"] as? Int == 1)
        #expect((root["children"] as? [[String: Any]])?.first?["nodeId"] as? Int == 2)
    }

    @Test
    func flushingPendingWorkDropsBufferedProtocolEventsAfterDocumentRequest() async {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        store.testSetPendingDocumentRequest(depth: 6, preserveState: false)
        store.testSetPendingProtocolEvents([
            ["method": "DOM.documentUpdated", "params": [:]],
            ["method": "DOM.childNodeInserted", "params": ["parentNodeId": 2]]
        ])

        let didRequestDocument = await store.testFlushPendingWork()

        #expect(didRequestDocument == true)
        #expect(store.testPendingProtocolEventCount == 0)
    }

    @Test
    func protocolDocumentResponseDoesNotMutateAuthoritativeGraphState() async {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))
        let originalGeneration = graphStore.documentGeneration
        let originalRootID = graphStore.rootID
        let originalEntryCount = graphStore.entriesByID.count

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        await store.testHandleProtocolPayload([
            "id": 7,
            "method": "DOM.getDocument",
            "params": [
                "depth": 4,
                "preserveState": false,
            ],
        ])

        #expect(graphStore.documentGeneration == originalGeneration)
        #expect(graphStore.rootID == originalRootID)
        #expect(graphStore.entriesByID.count == originalEntryCount)
    }

    @Test
    func booleanProtocolIdentifiersAreRejectedByStaleResponsePath() {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        #expect(store.testParseProtocolIdentifier(true as NSNumber) == nil)
        #expect(store.testParseProtocolIdentifier(NSNumber(value: 1.5)) == nil)
    }

    @Test
    func staleResponseRecoveryPreservesFrontendStateWhenGraphExists() async {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        await store.testRequestFreshDocumentAfterStaleNodeResponse()

        let pendingRequest = store.testPendingDocumentRequest
        #expect(pendingRequest != nil)
        #expect(pendingRequest?.preserveState == true)
        #expect(pendingRequest?.depth == session.configuration.fullReloadDepth)
    }

    @Test
    func staleSelectorPathResponseForMissingNodeDoesNotQueueDocumentRefresh() async {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: StubDOMFrontendStorePageDriver(graphStore: graphStore)
        )
        let store = WIDOMFrontendRuntime(session: session)

        store.testSetReady(true)
        await store.testHandleProtocolPayload([
            "id": 17,
            "method": "DOM.getSelectorPath",
            "params": [
                "nodeId": 999,
            ],
        ])

        #expect(store.testPendingDocumentRequest == nil)
    }

    @Test
    func requestChildNodesForNodeMissingFromAuthoritativeGraphDoesNotQueueDocumentRefresh() async {
        let graphStore = DOMGraphStore()
        graphStore.applySnapshot(.init(root: makeDocumentTree()))

        let pageDriver = StubDOMFrontendStorePageDriver(graphStore: graphStore)
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: pageDriver
        )
        let store = WIDOMFrontendRuntime(session: session)

        store.testSetReady(true)
        await store.testHandleProtocolPayload([
            "id": 23,
            "method": "DOM.requestChildNodes",
            "params": [
                "nodeId": 999,
            ],
        ])

        #expect(store.testPendingDocumentRequest == nil)
        #expect(pageDriver.requestedChildNodeIDs == [999])
    }
}

@MainActor
private final class StubDOMFrontendStorePageDriver: WIDOMBackend {
    weak var eventSink: (any WIDOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?
    let support = WIInspectorBackendSupport(
        availability: .unsupported,
        backendKind: .legacy,
        capabilities: [.domDomain]
    )
    private(set) var requestedChildNodeIDs: [Int] = []

    init(graphStore: DOMGraphStore) {
        _ = graphStore
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
        _ = preserveState
        _ = requestedDepth
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        requestedChildNodeIDs.append(parentNodeId)
        return []
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
        return .init(nodeId: nodeId, matched: .empty, computed: .empty)
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
        .init(cancelled: true, requiredDepth: 0)
    }

    func cancelSelectionMode() async {
    }

    func highlight(nodeId: Int) async {
        _ = nodeId
    }

    func hideHighlight() async {
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
                layoutFlags: ["rendered"],
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
                        layoutFlags: ["rendered"],
                        isRendered: true,
                        children: []
                    )
                ]
            )
        ]
    )
}

private func makeDocumentTreeWithMissingBodyChildren() -> DOMGraphNodeDescriptor {
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
                        children: []
                    )
                ]
            )
        ]
    )
}

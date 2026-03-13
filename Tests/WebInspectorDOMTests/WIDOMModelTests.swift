import Testing
import WebKit
import ObservationBridge
import WebInspectorTestSupport
#if canImport(AppKit)
import AppKit
#endif
@testable import WebInspectorUI
@testable import WebInspectorCore

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WIDOMModelTests {
    @Test
    func attachBuildsNativeTreeRowsFromTransportSnapshot() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let rowIDs = treeRowIDsRecorder(for: inspector)

        try? await session.reloadDocument()
        let loadedRows = await rowIDs.next(where: { $0.isEmpty == false })

        #expect(loadedRows.isEmpty == false)
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
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let rowIDs = treeRowIDsRecorder(for: inspector)

        try? await session.reloadDocument()
        _ = await rowIDs.next(where: { $0.contains(4) })

        let targetID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 4)
        inspector.toggleExpansion(of: targetID)
        let expandedRows = await rowIDs.next(where: { $0.contains(5) })

        #expect(expandedRows.contains(5))
        #expect(driver.requestedParentNodeIDs == [4])

        inspector.toggleExpansion(of: targetID)
        inspector.toggleExpansion(of: targetID)
        #expect(driver.requestedParentNodeIDs.count == 1)
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
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let rowIDs = treeRowIDsRecorder(for: inspector)

        try? await session.reloadDocument()
        let loadedRows = await rowIDs.next(where: { $0.isEmpty == false })

        #expect(loadedRows.isEmpty == false)
        #expect(inspector.treeRows.first?.id.nodeID == 1)
    }

    @Test
    func selectEntryUpdatesSelectionAndHighlightState() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let rootIDs = rootNodeIDRecorder(for: graphStore)

        try? await session.reloadDocument()
        _ = await rootIDs.next(where: { $0 != nil })

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)
        await driver.highlightCounter.wait(untilAtLeast: 1)

        #expect(inspector.selectedEntry?.id == bodyID)
        #expect(driver.highlightedNodeIDs == [3])

        inspector.selectEntry(nil)
        await driver.hideHighlightCounter.wait(untilAtLeast: 1)

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
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })
        let initialReloadCount = await driver.reloadCounter.snapshot()
        inspector.toggleSelectionMode()
        await driver.reloadCounter.wait(untilAtLeast: initialReloadCount + 1)

        #expect(session.configuration.snapshotDepth >= 13)
        #expect(driver.reloadRequestedDepths.contains(13))
        #expect(session.configuration.rootBootstrapDepth >= 13)
    }

    @Test
    func selectionSnapshotRefreshesMatchedStylesForSameSelectedNode() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)
        await driver.matchedStylesCounter.wait(untilAtLeast: 1)
        #expect(driver.matchedStylesRequests == [3])

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
        await driver.matchedStylesCounter.wait(untilAtLeast: 2)
        #expect(driver.matchedStylesRequests == [3, 3])
    }

    @Test
    func matchedStylesFailureDoesNotRetryForUnchangedSelection() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            matchedStylesError: StubDOMPageDriverError.missingNode
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let errorMessages = errorMessageRecorder(for: inspector)
        let projectionRevisions = graphProjectionRevisionRecorder(for: inspector)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)
        await driver.matchedStylesCounter.wait(untilAtLeast: 1)
        _ = await errorMessages.next(where: { $0 != nil })

        let previousRevision = inspector.graphProjectionRevision
        graphStore.applyMutationBundle(
            .init(events: [
                .attributeModified(nodeID: 2, name: "lang", value: "en", layoutFlags: nil, isRendered: nil)
            ])
        )
        _ = await projectionRevisions.next(where: { $0 > previousRevision })

        #expect(driver.matchedStylesRequests.count == 1)
        #expect(inspector.selectedEntry?.style.loadState == .failed)
        #expect(inspector.errorMessage == StubDOMPageDriverError.missingNode.localizedDescription)
    }

    @Test
    func invalidatedMatchedStylesRefreshesAgainForSameSelectionKey() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)
        await driver.matchedStylesCounter.wait(untilAtLeast: 1)
        #expect(driver.matchedStylesRequests == [3])

        graphStore.invalidateStyle(for: 3, reason: .manualRefresh)
        await driver.matchedStylesCounter.wait(untilAtLeast: 2)
        #expect(driver.matchedStylesRequests == [3, 3])
    }

    @Test
    func rapidSelectionSnapshotBurstRefreshesMatchedStylesForLatestRevision() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

        let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
        inspector.selectEntry(bodyID)
        await driver.matchedStylesCounter.wait(untilAtLeast: 1)
        #expect(driver.matchedStylesRequests == [3])
        #expect(driver.matchedStylesRequestRevisions.isEmpty == false)

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
        await driver.matchedStylesCounter.wait(untilAtLeast: 2)

        #expect(driver.matchedStylesRequests.count >= 2)
        #expect(driver.matchedStylesRequestRevisions.last == 3)
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
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let selectedSnapshots = selectedSnapshotRecorder(for: inspector)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

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
        let snapshot = await selectedSnapshots.next(where: { $0?.nodeID == 3 })

        #expect(snapshot?.nodeID == 3)
        #expect(inspector.selectedEntry?.id.nodeID == 3)
    }

    @Test
    func frontendSelectionMessagePublishesInspectorSelectedEntry() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let (inspector, frontendRuntime) = makeInspectorWithFrontendRuntime(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let selectedSnapshots = selectedSnapshotRecorder(for: inspector)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

        frontendRuntime.testHandleDOMSelectionMessage([
            "nodeId": 3,
            "preview": "<body>",
            "attributes": [],
            "path": ["html", "body"],
            "selectorPath": "html > body",
            "styleRevision": 1
        ])
        let snapshot = await selectedSnapshots.next(where: { $0?.nodeID == 3 })

        #expect(snapshot?.nodeID == 3)
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
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let (inspector, frontendRuntime) = makeInspectorWithFrontendRuntime(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let selectedSnapshots = selectedSnapshotRecorder(for: inspector)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })
        #expect(graphStore.entry(forNodeID: 3) != nil)
        #expect(graphStore.entry(forNodeID: 6) == nil)

        frontendRuntime.testHandleDOMSelectionMessage([
            "nodeId": 6,
            "preview": "<div id=\"target\">",
            "attributes": [
                ["name": "id", "value": "target"],
            ],
            "path": ["html", "body", "main", "div"],
            "selectorPath": "#target",
            "styleRevision": 1
        ])
        let recoveredSnapshot = await selectedSnapshots.next(where: { $0?.nodeID == 6 })

        #expect(recoveredSnapshot?.nodeID == 6)
        #expect(driver.reloadRequestedDepths == [4, 8])
        #expect(inspector.selectedEntry?.selectorPath == "#target")
        #expect(inspector.selectedEntry?.attributes.contains(where: { $0.name == "id" && $0.value == "target" }) == true)
    }

    @Test
    func repeatedProgrammaticSelectionDoesNotBlockSubsequentObservedSelectionRefresh() async {
        await withWebKitTestIsolation {
            let graphStore = DOMGraphStore()
            let driver = StubDOMPageDriver(
                graphStore: graphStore,
                rootSnapshot: .init(root: makeDocumentTree())
            )
            let session = WIDOMRuntime(
                configuration: .init(),
                graphStore: graphStore,
                backend: driver
            )
            let inspector = WIDOMStore(session: session)

            graphStore.applySnapshot(.init(root: makeDocumentTree()))
            #expect(graphStore.entry(forNodeID: 3) != nil)
            #expect(graphStore.entry(forNodeID: 2) != nil)

            let bodyID = DOMEntryID(documentGeneration: graphStore.documentGeneration, nodeID: 3)
            inspector.selectEntry(bodyID)
            let initialRefresh = await driver.matchedStylesEvents.next(where: { $0.nodeID == 3 })
            #expect(initialRefresh.nodeID == 3)

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
            let observedRefresh = await driver.matchedStylesEvents.next(where: { $0.nodeID == 2 })
            #expect(observedRefresh.nodeID == 2)
        }
    }

    @Test
    func staleProgrammaticSelectionDoesNotSuppressNextObservedSelectionRefresh() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree())
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)

        graphStore.applySnapshot(.init(root: makeDocumentTree()))

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
        await driver.matchedStylesCounter.wait(untilAtLeast: 1)
        #expect(driver.matchedStylesRequests.last == 3)
    }

    @Test
    func rapidFrontendSelectionMissesRecoverLatestRequestedNode() async {
        let graphStore = DOMGraphStore()
        let reloadGate = AsyncGate()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            reloadSnapshots: [
                .init(root: makeDocumentTree()),
                .init(root: makeRecoveryDocumentTree(nodeID: 6, idValue: "first-target")),
                .init(root: makeRecoveryDocumentTree(nodeID: 7, idValue: "second-target"))
            ],
            gatedReloadIndices: [2, 3],
            reloadGate: reloadGate
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let (inspector, frontendRuntime) = makeInspectorWithFrontendRuntime(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let selectedSnapshots = selectedSnapshotRecorder(for: inspector)

        inspector.attach(to: webView)
        _ = await rootIDs.next(where: { $0 != nil })

        frontendRuntime.testHandleDOMSelectionMessage([
            "nodeId": 6,
            "preview": "<div id=\"first-target\">",
            "attributes": [
                ["name": "id", "value": "first-target"],
            ],
            "path": ["html", "body", "main", "div"],
            "selectorPath": "#first-target",
            "styleRevision": 1
        ])
        frontendRuntime.testHandleDOMSelectionMessage([
            "nodeId": 7,
            "preview": "<div id=\"second-target\">",
            "attributes": [
                ["name": "id", "value": "second-target"],
            ],
            "path": ["html", "body", "main", "div"],
            "selectorPath": "#second-target",
            "styleRevision": 2
        ])
        await reloadGate.open()
        let recoveredSnapshot = await selectedSnapshots.next(where: {
            $0?.nodeID == 7
                && $0?.selectorPath == "#second-target"
                && $0?.attributes.contains(.init(name: "id", value: "second-target")) == true
        })

        #expect(recoveredSnapshot?.nodeID == 7)
    }

    @Test
    func attachBackgroundReloadCoalescesMatchingExplicitReload() async {
        let graphStore = DOMGraphStore()
        let reloadGate = AsyncGate()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            gatedReloadIndices: [1],
            reloadGate: reloadGate,
            requiresAttachedWebViewForReload: true
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let rowIDs = treeRowIDsRecorder(for: inspector)

        inspector.attach(to: webView)
        await driver.reloadCounter.wait(untilAtLeast: 1)

        let explicitReload = Task { @MainActor in
            await inspector.reloadFrontend()
        }

        await reloadGate.open()
        await explicitReload.value

        let loadedRootID = await rootIDs.next(where: { $0 != nil })
        let loadedRowIDs = await rowIDs.next(where: { $0.isEmpty == false })

        #expect(loadedRootID == 1)
        #expect(loadedRowIDs.isEmpty == false)
        #expect(await driver.reloadCounter.snapshot() == 1)
        #expect(driver.reloadRequestedDepths.count == 1)
    }

    @Test
    func explicitReloadReRunsAfterSnapshotDepthChangesDuringBackgroundReload() async {
        let graphStore = DOMGraphStore()
        let reloadGate = AsyncGate()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            gatedReloadIndices: [1],
            reloadGate: reloadGate,
            requiresAttachedWebViewForReload: true
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let initialDepth = session.configuration.rootBootstrapDepth

        inspector.attach(to: webView)
        await driver.reloadCounter.wait(untilAtLeast: 1)

        inspector.updateSnapshotDepth(10)
        let explicitReload = Task { @MainActor in
            await inspector.reloadFrontend()
        }
        await reloadGate.open()
        await explicitReload.value
        await driver.reloadCounter.wait(untilAtLeast: 2)

        #expect(await driver.reloadCounter.snapshot() == 2)
        #expect(driver.reloadRequestedDepths == [initialDepth, 10])
    }

    @Test
    func detachCancelsPendingBackgroundReloadWithoutLateTreeMutation() async {
        let graphStore = DOMGraphStore()
        let reloadGate = AsyncGate()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            gatedReloadIndices: [1],
            reloadGate: reloadGate,
            requiresAttachedWebViewForReload: true
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)
        let webView = makeIsolatedTestWebView()
        let rootIDs = rootNodeIDRecorder(for: graphStore)
        let rowIDs = treeRowIDsRecorder(for: inspector)

        inspector.attach(to: webView)
        await driver.reloadCounter.wait(untilAtLeast: 1)

        inspector.detach()
        #expect(graphStore.rootID == nil)
        #expect(inspector.treeRows.isEmpty)

        await reloadGate.open()
        for _ in 0..<8 {
            await Task.yield()
        }

        let observedRootIDs = await rootIDs.snapshot()
        let observedRowIDs = await rowIDs.snapshot()

        #expect(graphStore.rootID == nil)
        #expect(inspector.treeRows.isEmpty)
        #expect(observedRootIDs.contains(where: { $0 != nil }) == false)
        #expect(observedRowIDs.contains(where: { $0.isEmpty == false }) == false)
    }

#if canImport(AppKit)
    @Test
    func copySelectionFallsBackToSystemPasteboardWithoutUIBridge() async {
        let graphStore = DOMGraphStore()
        let driver = StubDOMPageDriver(
            graphStore: graphStore,
            rootSnapshot: .init(root: makeDocumentTree()),
            selectionCopyTextResult: "<body>Hello</body>"
        )
        let session = WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: driver
        )
        let inspector = WIDOMStore(session: session)

        graphStore.applySnapshot(.init(root: makeDocumentTree()))
        graphStore.applySelectionSnapshot(
            .init(
                nodeID: 3,
                preview: "<body>",
                attributes: [],
                path: ["html", "body"],
                selectorPath: "html > body",
                styleRevision: 0
            )
        )
        NSPasteboard.general.clearContents()

        inspector.copySelection(.html)
        await driver.selectionCopyCounter.wait(untilAtLeast: 1)

        #expect(NSPasteboard.general.string(forType: .string) == "<body>Hello</body>")
    }
#endif
}

@MainActor
private func makeInspectorWithFrontendRuntime(
    session: WIDOMRuntime
) -> (inspector: WIDOMStore, frontendRuntime: WIDOMFrontendRuntime) {
    let frontendRuntime = WIDOMFrontendRuntime(session: session)
    let inspector = WIDOMStore(session: session, frontendBridge: frontendRuntime)
    return (inspector, frontendRuntime)
}

@MainActor
private final class StubDOMPageDriver: WIDOMBackend {
    weak var eventSink: (any WIDOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?
    let support = WIBackendSupport(
        availability: .unsupported,
        backendKind: .legacy,
        capabilities: [.domDomain]
    )

    private let graphStore: DOMGraphStore
    private let reloadSnapshots: [DOMGraphSnapshot]
    private let requestedChildren: [Int: [DOMGraphNodeDescriptor]]
    private let selectionModeResult: DOMSelectionModeResult
    private let selectionCopyTextResult: String
    private let matchedStylesError: (any Error)?
    private var pendingSelectedNodeID: Int?
    private let gatedReloadIndices: Set<Int>
    private let reloadGate: AsyncGate?
    private let requiresAttachedWebViewForReload: Bool

    private(set) var requestedParentNodeIDs: [Int] = []
    private(set) var highlightedNodeIDs: [Int] = []
    private(set) var hideHighlightCallCount = 0
    private(set) var reloadRequestedDepths: [Int] = []
    private(set) var matchedStylesRequests: [Int] = []
    private(set) var matchedStylesRequestRevisions: [Int] = []
    let reloadCounter = AsyncCounter()
    let childRequestCounter = AsyncCounter()
    let matchedStylesCounter = AsyncCounter()
    let matchedStylesEvents = AsyncValueQueue<DOMMatchedStylesRequestEvent>()
    let highlightCounter = AsyncCounter()
    let hideHighlightCounter = AsyncCounter()
    let selectionCopyCounter = AsyncCounter()

    init(
        graphStore: DOMGraphStore,
        rootSnapshot: DOMGraphSnapshot,
        reloadSnapshots: [DOMGraphSnapshot]? = nil,
        requestedChildren: [Int: [DOMGraphNodeDescriptor]] = [:],
        selectionModeResult: DOMSelectionModeResult = .init(cancelled: true, requiredDepth: 0),
        selectionCopyTextResult: String = "",
        matchedStylesError: (any Error)? = nil,
        gatedReloadIndices: Set<Int> = [],
        reloadGate: AsyncGate? = nil,
        requiresAttachedWebViewForReload: Bool = false
    ) {
        self.graphStore = graphStore
        self.reloadSnapshots = reloadSnapshots ?? [rootSnapshot]
        self.requestedChildren = requestedChildren
        self.selectionModeResult = selectionModeResult
        self.selectionCopyTextResult = selectionCopyTextResult
        self.matchedStylesError = matchedStylesError
        self.gatedReloadIndices = gatedReloadIndices
        self.reloadGate = reloadGate
        self.requiresAttachedWebViewForReload = requiresAttachedWebViewForReload
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
        let reloadIndex = await reloadCounter.increment()
        reloadRequestedDepths.append(requestedDepth ?? 0)
        _ = requestedDepth
        if gatedReloadIndices.contains(reloadIndex) {
            await reloadGate?.wait()
        }
        try Task.checkCancellation()
        guard !requiresAttachedWebViewForReload || webView != nil else {
            throw CancellationError()
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
        await childRequestCounter.increment()
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
        await matchedStylesCounter.increment()
        matchedStylesRequests.append(nodeId)
        let revision = graphStore.selectedEntry?.style.sourceRevision ?? -1
        matchedStylesRequestRevisions.append(revision)
        await matchedStylesEvents.push(.init(nodeID: nodeId, revision: revision))
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
        await highlightCounter.increment()
        highlightedNodeIDs.append(nodeId)
    }

    func hideHighlight() async {
        await hideHighlightCounter.increment()
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
        await selectionCopyCounter.increment()
        return selectionCopyTextResult
    }
}

private struct DOMSelectedSnapshot: Equatable, Sendable {
    let nodeID: Int?
    let selectorPath: String
    let attributes: [DOMAttributeSummary]
}

private struct DOMMatchedStylesRequestEvent: Equatable, Sendable {
    let nodeID: Int
    let revision: Int
}

private struct DOMAttributeSummary: Equatable, Sendable {
    let name: String
    let value: String
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
private func rootNodeIDRecorder(for graphStore: DOMGraphStore) -> ObservationRecorder<Int?> {
    let recorder = ObservationRecorder<Int?>()
    recorder.record { didChange in
        graphStore.observe(\.rootID, options: [.removeDuplicates]) { rootID in
            didChange(rootID?.nodeID)
        }
    }
    return recorder
}

@MainActor
private func treeRowIDsRecorder(for inspector: WIDOMStore) -> ObservationRecorder<[Int]> {
    let recorder = ObservationRecorder<[Int]>()
    recorder.record { didChange in
        inspector.observe(\.graphProjectionRevision, options: [.removeDuplicates]) { _ in
            didChange(inspector.treeRows.map(\.id.nodeID))
        }
    }
    return recorder
}

@MainActor
private func selectedSnapshotRecorder(
    for inspector: WIDOMStore
) -> ObservationRecorder<DOMSelectedSnapshot?> {
    let recorder = ObservationRecorder<DOMSelectedSnapshot?>()
    recorder.record { didChange in
        inspector.observe(\.graphProjectionRevision, options: [.removeDuplicates]) { _ in
            let snapshot = inspector.selectedEntry.map { entry in
                DOMSelectedSnapshot(
                    nodeID: entry.id.nodeID,
                    selectorPath: entry.selectorPath,
                    attributes: entry.attributes.map { DOMAttributeSummary(name: $0.name, value: $0.value) }
                )
            }
            didChange(snapshot)
        }
    }
    return recorder
}

@MainActor
private func errorMessageRecorder(for inspector: WIDOMStore) -> ObservationRecorder<String?> {
    let recorder = ObservationRecorder<String?>()
    recorder.record { didChange in
        inspector.observe(\.errorMessage, options: [.removeDuplicates]) { errorMessage in
            didChange(errorMessage)
        }
    }
    return recorder
}

@MainActor
private func graphProjectionRevisionRecorder(
    for inspector: WIDOMStore
) -> ObservationRecorder<UInt64> {
    let recorder = ObservationRecorder<UInt64>()
    recorder.record { didChange in
        inspector.observe(\.graphProjectionRevision, options: [.removeDuplicates]) { revision in
            didChange(revision)
        }
    }
    return recorder
}

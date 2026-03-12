#if canImport(AppKit)
import Testing
import AppKit
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorCore
@testable import WebInspectorDOM
@testable import WebInspectorUI

@MainActor
struct WIDOMDetailViewControllerAppKitTests {
    @Test
    func detailViewRefreshesWhenSelectionSnapshotChanges() async {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        let viewController = WIDOMDetailViewController(inspector: inspector)
        let renderRefreshes = AsyncValueQueue<Int>()
        viewController.onRenderRefreshForTesting = { count in
            Task {
                await renderRefreshes.push(count)
            }
        }
        let window = makeWindow(contentViewController: viewController)
        defer {
            disposeWindow(window)
        }

        viewController.loadViewIfNeeded()
        let initialRefreshCount = viewController.testRenderRefreshCount

        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                nodeID: 6,
                preview: "<span data-state=\"3\">Latest 3</span>",
                attributes: [
                    DOMAttribute(nodeId: 6, name: "aria-label", value: "スノーボード"),
                    DOMAttribute(nodeId: 6, name: "class", value: "hero-label"),
                    DOMAttribute(nodeId: 6, name: "data-state", value: "3")
                ],
                path: ["html", "body", "div", "span"],
                selectorPath: "#hplogo > span.state-3",
                styleRevision: 3
            )
        )

        let updatedRefreshCount = await renderRefreshes.next(where: { $0 > initialRefreshCount })
        #expect(updatedRefreshCount > initialRefreshCount)
    }

    @Test
    func detailViewRecoversSelectionAfterFrontendMiss() async {
        let graphStore = DOMGraphStore()
        let driver = AppKitDetailRecoveryPageDriver(
            graphStore: graphStore,
            reloadSnapshots: [
                .init(root: makeDetailRecoveryInitialTree()),
                .init(root: makeDetailRecoveryResolvedTree())
            ]
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMInspectorStore(session: session)
        let webView = WKWebView(frame: .zero)
        let rootNodeIDs = sharedRootNodeIDRecorder(for: graphStore)
        let selectedSnapshots = selectedSnapshotRecorder(for: inspector)
        inspector.attach(to: webView)

        _ = await rootNodeIDs.next(where: { $0 != nil })
        #expect(inspector.session.graphStore.entry(forNodeID: 3) != nil)
        #expect(inspector.session.graphStore.entry(forNodeID: 6) == nil)

        let viewController = WIDOMDetailViewController(inspector: inspector)
        let renderRefreshes = AsyncValueQueue<Int>()
        viewController.onRenderRefreshForTesting = { count in
            Task {
                await renderRefreshes.push(count)
            }
        }
        let window = makeWindow(contentViewController: viewController)
        defer {
            disposeWindow(window)
        }

        viewController.loadViewIfNeeded()
        let initialRefreshCount = viewController.testRenderRefreshCount
        #expect(inspector.selectedEntry == nil)

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

        let recoveredSelection = await selectedSnapshots.next(where: {
            $0?.nodeID == 6 && $0?.selectorPath == "#target"
        })
        let recoveredRefreshCount = await renderRefreshes.next(where: { $0 > initialRefreshCount })
        #expect(recoveredSelection?.nodeID == 6)
        #expect(recoveredRefreshCount > initialRefreshCount)
    }
}

@MainActor
private func makeWindow(contentViewController: NSViewController) -> NSWindow {
    let window = NSWindow(contentViewController: contentViewController)
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func disposeWindow(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentViewController = nil
    window.close()
}

private struct DOMSelectionSummary: Equatable, Sendable {
    let nodeID: Int?
    let selectorPath: String
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
private func selectedSnapshotRecorder(
    for inspector: WIDOMInspectorStore
) -> ObservationRecorder<DOMSelectionSummary?> {
    let recorder = ObservationRecorder<DOMSelectionSummary?>()
    recorder.record { didChange in
        inspector.observe(\.graphProjectionRevision, options: [.removeDuplicates]) { _ in
            didChange(
                inspector.selectedEntry.map {
                    DOMSelectionSummary(nodeID: $0.id.nodeID, selectorPath: $0.selectorPath)
                }
            )
        }
    }
    return recorder
}

@MainActor
private final class AppKitDetailRecoveryPageDriver: DOMPageDriving {
    weak var eventSink: (any DOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?

    private let graphStore: DOMGraphStore
    private let reloadSnapshots: [DOMGraphSnapshot]
    private var pendingSelectedNodeID: Int?
    private var reloadCount = 0

    init(graphStore: DOMGraphStore, reloadSnapshots: [DOMGraphSnapshot]) {
        self.graphStore = graphStore
        self.reloadSnapshots = reloadSnapshots
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
        _ = requestedDepth
        let snapshot = reloadSnapshots[min(reloadCount, reloadSnapshots.count - 1)]
        reloadCount += 1
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
        _ = parentNodeId
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
        .init(cancelled: true, requiredDepth: 0)
    }

    func cancelSelectionMode() async {}

    func highlight(nodeId: Int) async {
        _ = nodeId
    }

    func hideHighlight() async {}

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

private func makeDetailRecoveryInitialTree() -> DOMGraphNodeDescriptor {
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

private func makeDetailRecoveryResolvedTree() -> DOMGraphNodeDescriptor {
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
                                        nodeID: 6,
                                        nodeType: 1,
                                        nodeName: "DIV",
                                        localName: "div",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(nodeId: 6, name: "id", value: "target")],
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
#endif

#if canImport(UIKit)
import Testing
import UIKit
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorCore
@testable import WebInspectorDOM
@testable import WebInspectorUI

@MainActor
struct WIDOMDetailViewControllerTests {
    @Test
    func detailViewAppliesLatestSelectionSnapshotAfterRapidDOMBursts() async {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        let viewController = WIDOMDetailViewController(inspector: inspector)
        let snapshotRevisions = AsyncValueQueue<UInt64>()
        viewController.onSnapshotAppliedForTesting = { revision in
            Task {
                await snapshotRevisions.push(revision)
            }
        }
        let host = UINavigationController(rootViewController: viewController)
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        while listCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) != "#hplogo > span" {
            _ = await snapshotRevisions.next()
        }

        let graphStore = inspector.session.graphStore
        for revision in 1...3 {
            graphStore.applySelectionSnapshot(
                .init(
                    nodeID: 6,
                    preview: "<span data-state=\"\(revision)\">Latest \(revision)</span>",
                    attributes: [
                        DOMAttribute(nodeId: 6, name: "aria-label", value: "スノーボード"),
                        DOMAttribute(nodeId: 6, name: "class", value: "hero-label"),
                        DOMAttribute(nodeId: 6, name: "data-state", value: "\(revision)")
                    ],
                    path: ["html", "body", "div", "span"],
                    selectorPath: "#hplogo > span.state-\(revision)",
                    styleRevision: revision
                )
            )
        }

        while listCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) != "#hplogo > span.state-3" {
            _ = await snapshotRevisions.next()
        }
        #expect(
            listCellText(
                in: viewController.collectionView,
                at: IndexPath(item: 0, section: 0)
            ) == "<span data-state=\"3\">Latest 3</span>"
        )
    }

    @Test
    func detailViewRecoversSelectionAfterFrontendMiss() async {
        let graphStore = DOMGraphStore()
        let driver = UIKitDetailRecoveryPageDriver(
            graphStore: graphStore,
            reloadSnapshots: [
                .init(root: makeDetailRecoveryInitialTree()),
                .init(root: makeDetailRecoveryResolvedTree())
            ]
        )
        let session = DOMSession(
            configuration: .init(),
            graphStore: graphStore,
            pageAgent: driver
        )
        let inspector = WIDOMInspectorStore(session: session)
        let webView = WKWebView(frame: .zero)
        let rootNodeIDs = sharedRootNodeIDRecorder(for: graphStore)
        inspector.attach(to: webView)

        _ = await rootNodeIDs.next(where: { $0 != nil })
        #expect(inspector.session.graphStore.entry(forNodeID: 3) != nil)
        #expect(inspector.session.graphStore.entry(forNodeID: 6) == nil)

        let viewController = WIDOMDetailViewController(inspector: inspector)
        let snapshotRevisions = AsyncValueQueue<UInt64>()
        viewController.onSnapshotAppliedForTesting = { revision in
            Task {
                await snapshotRevisions.push(revision)
            }
        }
        let host = UINavigationController(rootViewController: viewController)
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(viewController.collectionView.isHidden == true)

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

        while listCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) != "#target" {
            _ = await snapshotRevisions.next()
        }
        #expect(viewController.collectionView.isHidden == false)
        #expect(
            listCellText(
                in: viewController.collectionView,
                at: IndexPath(item: 0, section: 0)
            ) == "<div id=\"target\">"
        )
    }

    private func listCellText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        collectionView.layoutIfNeeded()
        guard
            indexPath.section < collectionView.numberOfSections,
            indexPath.item < collectionView.numberOfItems(inSection: indexPath.section),
            let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
            let content = cell.contentConfiguration as? UIListContentConfiguration
        else {
            return nil
        }
        return content.text
    }
}

@MainActor
private func makeWindow(rootViewController: UIViewController) -> UIWindow {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}

@MainActor
private final class UIKitDetailRecoveryPageDriver: DOMPageDriving {
    weak var eventSink: (any DOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?

    private let graphStore: DOMGraphStore
    private let reloadSnapshots: [DOMGraphSnapshot]
    private var pendingSelectedNodeID: Int?
    private var reloadCount = 0

    init(graphStore: DOMGraphStore, reloadSnapshots: [DOMGraphSnapshot]) {
        self.graphStore = graphStore
        self.reloadSnapshots = reloadSnapshots
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
        _ = requestedDepth
        let snapshot = reloadSnapshots[min(reloadCount, reloadSnapshots.count - 1)]
        reloadCount += 1
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
        _ = parentNodeId
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
        .init(cancelled: true, requiredDepth: 0)
    }

    func cancelSelectionMode() async {}

    func highlight(nodeId: Int) async {
        _ = nodeId
    }

    func hideHighlight() async {}

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

private func makeDetailRecoveryInitialTree() -> DOMGraphNodeDescriptor {
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

private func makeDetailRecoveryResolvedTree() -> DOMGraphNodeDescriptor {
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
                                        nodeID: 6,
                                        nodeType: 1,
                                        nodeName: "DIV",
                                        localName: "div",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(nodeId: 6, name: "id", value: "target")],
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
#endif

@MainActor
private func sharedRootNodeIDRecorder(for graphStore: DOMGraphStore) -> ObservationRecorder<Int?> {
    let recorder = ObservationRecorder<Int?>()
    recorder.record { didChange in
        graphStore.observe(\.rootID, options: [.removeDuplicates]) { rootID in
            didChange(rootID?.nodeID)
        }
    }
    return recorder
}

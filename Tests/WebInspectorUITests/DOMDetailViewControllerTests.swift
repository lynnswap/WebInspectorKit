#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMDetailViewControllerTests {
    @Test
    func detailViewUpdatesPreviewWithoutApplyingAnotherSnapshot() async throws {
        let inspector = makeInspector(
            selectedLocalID: 42,
            preview: "<div class=\"before\">",
            selectorPath: "#target",
            attributes: [DOMAttribute(nodeId: 42, name: "class", value: "before")]
        )
        let (viewController, window) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let collectionView = try #require(viewController.collectionView)
        let initialReady = await waitUntil {
            viewController.snapshotApplyCountForTesting > 0
                && self.visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "<div class=\"before\">"
        }
        #expect(initialReady)

        let initialSnapshotCount = try #require(await stableSnapshotApplyCount(for: viewController))
        inspector.selectedEntry?.preview = "<div class=\"after\">"

        let previewUpdated = await waitUntil {
            self.visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "<div class=\"after\">"
        }
        #expect(previewUpdated)
        #expect(viewController.snapshotApplyCountForTesting == initialSnapshotCount)
    }

    @Test
    func detailViewUpdatesSelectorPathWithoutApplyingAnotherSnapshot() async throws {
        let inspector = makeInspector(
            selectedLocalID: 42,
            preview: "<div>",
            selectorPath: "#before",
            attributes: [DOMAttribute(nodeId: 42, name: "class", value: "before")]
        )
        let (viewController, window) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let collectionView = try #require(viewController.collectionView)
        let initialReady = await waitUntil {
            viewController.snapshotApplyCountForTesting > 0
                && self.visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "#before"
        }
        #expect(initialReady)

        let initialSnapshotCount = try #require(await stableSnapshotApplyCount(for: viewController))
        inspector.selectedEntry?.selectorPath = "#after"

        let selectorUpdated = await waitUntil {
            self.visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "#after"
        }
        #expect(selectorUpdated)
        #expect(viewController.snapshotApplyCountForTesting == initialSnapshotCount)
    }

    @Test
    func detailViewIgnoresMutationsOnUnselectedNode() async throws {
        let inspector = makeInspector(
            selectedLocalID: 42,
            preview: "<div>",
            selectorPath: "#target",
            attributes: [DOMAttribute(nodeId: 42, name: "class", value: "selected")],
            extraTreeChildren: [makeNode(localID: 99, attributes: [DOMAttribute(nodeId: 99, name: "data-other", value: "old")])]
        )
        let (viewController, window) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let collectionView = try #require(viewController.collectionView)
        let initialReady = await waitUntil {
            viewController.snapshotApplyCountForTesting > 0
                && self.visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "<div>"
        }
        #expect(initialReady)

        let initialSnapshotCount = try #require(await stableSnapshotApplyCount(for: viewController))
        inspector.session.graphStore.applyMutationBundle(
            .init(
                events: [
                    .attributeModified(
                        nodeLocalID: 99,
                        name: "data-other",
                        value: "new",
                        layoutFlags: nil,
                        isRendered: nil
                    )
                ]
            )
        )

        let unchanged = await waitUntil {
            self.visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "<div>"
        }
        #expect(unchanged)
        #expect(viewController.snapshotApplyCountForTesting == initialSnapshotCount)
    }

    @Test
    func detailViewUpdatesAttributeValueWithoutApplyingAnotherSnapshot() async throws {
        let inspector = makeInspector(
            selectedLocalID: 42,
            preview: "<div>",
            selectorPath: "#target",
            attributes: [DOMAttribute(nodeId: 42, name: "class", value: "before")]
        )
        let (viewController, window) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let collectionView = try #require(viewController.collectionView)
        let initialReady = await waitUntil {
            viewController.snapshotApplyCountForTesting > 0
                && self.visibleTextViewText(in: collectionView, at: IndexPath(item: 0, section: 3)) == "before"
        }
        #expect(initialReady)

        let initialSnapshotCount = try #require(await stableSnapshotApplyCount(for: viewController))
        inspector.session.graphStore.updateSelectedAttribute(name: "class", value: "after")

        let valueUpdated = await waitUntil {
            self.visibleTextViewText(in: collectionView, at: IndexPath(item: 0, section: 3)) == "after"
        }
        #expect(valueUpdated)
        #expect(viewController.snapshotApplyCountForTesting == initialSnapshotCount)
    }

    @Test
    func detailViewAppliesSnapshotWhenAttributeStructureChanges() async throws {
        let inspector = makeInspector(
            selectedLocalID: 42,
            preview: "<div>",
            selectorPath: "#target",
            attributes: [DOMAttribute(nodeId: 42, name: "class", value: "value")]
        )
        let (viewController, window) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let collectionView = try #require(viewController.collectionView)
        let initialReady = await waitUntil {
            viewController.snapshotApplyCountForTesting > 0
                && collectionView.numberOfItems(inSection: 3) == 1
        }
        #expect(initialReady)

        let initialSnapshotCount = try #require(await stableSnapshotApplyCount(for: viewController))
        inspector.session.graphStore.updateSelectedAttribute(name: "id", value: "target")

        let structureUpdated = await waitUntil {
            collectionView.numberOfItems(inSection: 3) == 2
                && viewController.snapshotApplyCountForTesting > initialSnapshotCount
        }
        #expect(structureUpdated)
    }

    @Test
    func detailViewTracksReplacementOfSelectedEntryWithSameLocalID() async throws {
        let inspector = makeInspector(
            selectedLocalID: 42,
            preview: "<div>",
            selectorPath: "#target",
            attributes: [DOMAttribute(nodeId: 42, name: "class", value: "before")],
            extraTreeChildren: [makeNode(localID: 99)]
        )
        let originalSelection = inspector.selectedEntry
        let (viewController, window) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let collectionView = try #require(viewController.collectionView)
        let initialReady = await waitUntil {
            viewController.snapshotApplyCountForTesting > 0
                && self.visibleTextViewText(in: collectionView, at: IndexPath(item: 0, section: 3)) == "before"
        }
        #expect(initialReady)

        let initialSnapshotCount = try #require(await stableSnapshotApplyCount(for: viewController))
        inspector.session.graphStore.applyMutationBundle(
            .init(
                events: [
                    .setChildNodes(
                        parentLocalID: 1,
                        nodes: [
                            makeNode(localID: 42, attributes: [DOMAttribute(nodeId: 42, name: "class", value: "replaced")]),
                            makeNode(localID: 99),
                        ]
                    )
                ]
            )
        )

        let replacementTracked = await waitUntil {
            inspector.selectedEntry !== originalSelection
                && collectionView.numberOfItems(inSection: 3) == 1
                && self.visibleTextViewText(in: collectionView, at: IndexPath(item: 0, section: 3)) == "replaced"
                && viewController.snapshotApplyCountForTesting > initialSnapshotCount
        }
        #expect(replacementTracked)
    }

    private func makeInspector(
        selectedLocalID: UInt64,
        preview: String,
        selectorPath: String,
        attributes: [DOMAttribute],
        extraTreeChildren: [DOMGraphNodeDescriptor] = []
    ) -> WIDOMModel {
        let controller = WIInspectorController()
        let inspector = controller.dom

        inspector.session.graphStore.applySnapshot(
            .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(localID: selectedLocalID, attributes: attributes)
                    ] + extraTreeChildren
                )
            )
        )
        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
                preview: preview,
                attributes: attributes,
                path: ["html", "body", "div"],
                selectorPath: selectorPath,
                styleRevision: 0
            )
        )
        return inspector
    }

    private func makeHostedDetailViewController(
        inspector: WIDOMModel
    ) -> (WIDOMDetailViewController, UIWindow) {
        let viewController = WIDOMDetailViewController(inspector: inspector)
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        viewController.collectionView?.layoutIfNeeded()
        return (viewController, window)
    }

    private func tearDown(window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func visibleListCellText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return nil
        }
        return configuration.text
    }

    private func visibleTextViewText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath) else {
            return nil
        }
        return firstSubview(of: UITextView.self, in: cell.contentView)?.text
    }

    private func firstSubview<ViewType: UIView>(of type: ViewType.Type, in view: UIView) -> ViewType? {
        if let matched = view as? ViewType {
            return matched
        }
        for subview in view.subviews {
            if let matched = firstSubview(of: type, in: subview) {
                return matched
            }
        }
        return nil
    }

    private func waitUntil(maxTicks: Int = 256, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func stableSnapshotApplyCount(
        for viewController: WIDOMDetailViewController,
        stableTicks: Int = 8,
        maxTicks: Int = 256
    ) async -> Int? {
        var lastCount = viewController.snapshotApplyCountForTesting
        var currentStableTicks = 0
        for _ in 0..<maxTicks {
            await Task.yield()
            let currentCount = viewController.snapshotApplyCountForTesting
            if currentCount == lastCount {
                currentStableTicks += 1
                if currentStableTicks >= stableTicks {
                    return currentCount
                }
            } else {
                lastCount = currentCount
                currentStableTicks = 0
            }
        }
        return nil
    }

    private func makeNode(
        localID: UInt64,
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = []
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: Int(localID),
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            nodeValue: "",
            attributes: attributes,
            childCount: children.count,
            layoutFlags: [],
            isRendered: true,
            children: children
        )
    }
}
#endif

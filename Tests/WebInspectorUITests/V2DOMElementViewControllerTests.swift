#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct V2DOMElementViewControllerTests {
    @Test
    func elementViewShowsEmptyStateWithoutSelection() async {
        let runtime = V2_WIDOMRuntime()
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let emptyStateReady = await waitUntil {
            viewController.isShowingEmptyStateForTesting
        }
        #expect(emptyStateReady)
        #expect(viewController.collectionView.numberOfSections == 0)
    }

    @Test
    func elementViewRendersSelectedNodeSections() async throws {
        let runtime = V2_WIDOMRuntime()
        seedSelectedNode(
            into: runtime,
            preview: "<div id=\"selected\" class=\"hero\">",
            selectorPath: "#selected",
            attributes: [
                DOMAttribute(name: "id", value: "selected"),
                DOMAttribute(name: "class", value: "hero"),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let initialReady = await waitUntil {
            viewController.collectionView.numberOfSections == 3
                && viewController.collectionView.numberOfItems(inSection: 0) == 1
                && viewController.collectionView.numberOfItems(inSection: 1) == 1
                && viewController.collectionView.numberOfItems(inSection: 2) == 2
                && visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#selected"
        }
        #expect(initialReady)
        #expect(viewController.isShowingEmptyStateForTesting == false)
        #expect(viewController.collectionView.numberOfSections == 3)
        #expect(viewController.collectionView.numberOfItems(inSection: 0) == 1)
        #expect(viewController.collectionView.numberOfItems(inSection: 1) == 1)
        #expect(viewController.collectionView.numberOfItems(inSection: 2) == 2)
        #expect(
            visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 0))
                == "<div id=\"selected\" class=\"hero\">"
        )
        #expect(visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#selected")
        #expect(visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2)) == "id")
    }

    @Test
    func elementViewReconfiguresAttributeValueChanges() async throws {
        let runtime = V2_WIDOMRuntime()
        seedSelectedNode(
            into: runtime,
            preview: "<div id=\"selected\">",
            selectorPath: "#selected",
            attributes: [
                DOMAttribute(name: "id", value: "selected"),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let initialReady = await waitUntil {
            visibleListCellSecondaryText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
                == "selected"
        }
        #expect(initialReady)

        runtime.document.selectedNode?.attributes = [
            DOMAttribute(name: "id", value: "updated"),
        ]

        let valueUpdated = await waitUntil {
            visibleListCellSecondaryText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
                == "updated"
        }
        #expect(valueUpdated)

        #expect(viewController.collectionView.numberOfSections == 3)
        #expect(viewController.collectionView.numberOfItems(inSection: 2) == 1)
        #expect(
            visibleListCellSecondaryText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
                == "updated"
        )
    }

    @Test
    func elementViewUpdatesSelectorTextChanges() async throws {
        let runtime = V2_WIDOMRuntime()
        seedSelectedNode(
            into: runtime,
            preview: "<div id=\"selected\">",
            selectorPath: "#before",
            attributes: [
                DOMAttribute(name: "id", value: "selected"),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let initialReady = await waitUntil {
            visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#before"
        }
        #expect(initialReady)
        let selectorTextView = visibleTextView(in: viewController.collectionView, at: IndexPath(item: 0, section: 1))
        #expect(selectorTextView?.isSelectable == true)
        #expect(selectorTextView?.isEditable == false)

        runtime.document.selectedNode?.selectorPath = "#after"

        let selectorUpdated = await waitUntil {
            visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#after"
        }
        #expect(selectorUpdated)
    }

    private func seedSelectedNode(
        into runtime: V2_WIDOMRuntime,
        preview: String,
        selectorPath: String,
        attributes: [DOMAttribute]
    ) {
        runtime.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 42, attributes: attributes)]
                )
            )
        )
        runtime.document.applySelectionSnapshot(
            .init(
                localID: 42,
                preview: preview,
                attributes: attributes,
                path: ["html", "body", "div"],
                selectorPath: selectorPath,
                styleRevision: 0
            )
        )
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

    private func makeHostedElementViewController(
        runtime: V2_WIDOMRuntime
    ) -> (V2_DOMElementViewController, UIWindow) {
        let viewController = V2_DOMElementViewController(dom: runtime)
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        viewController.collectionView.layoutIfNeeded()
        return (viewController, window)
    }

    private func tearDown(window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func visibleListCellText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return visibleTextView(in: collectionView.cellForItem(at: indexPath)?.contentView)?.text
        }
        return configuration.text
    }

    private func visibleTextView(in collectionView: UICollectionView, at indexPath: IndexPath) -> UITextView? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        return visibleTextView(in: collectionView.cellForItem(at: indexPath)?.contentView)
    }

    private func visibleTextView(in view: UIView?) -> UITextView? {
        guard let view else {
            return nil
        }
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = visibleTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func visibleListCellSecondaryText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return nil
        }
        return configuration.secondaryText
    }

    private func waitUntil(maxTicks: Int = 1024, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
}
#endif

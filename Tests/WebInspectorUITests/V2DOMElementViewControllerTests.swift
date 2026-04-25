#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct V2DOMElementViewControllerTests {
    @Test
    func elementViewShowsEmptyStateWithoutSelection() {
        let runtime = V2_WIDOMRuntime()
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        #expect(viewController.isShowingEmptyStateForTesting)
        #expect(viewController.collectionView.numberOfSections == 0)
    }

    @Test
    func elementViewRendersSelectedNodeSections() throws {
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
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return nil
        }
        return configuration.text
    }
}
#endif

#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM

@MainActor
package struct DOMTabController {
    package let tabID = WebInspectorTab.dom.id
    package let descriptor = WebInspectorTab.DisplayDescriptor(
        title: WebInspectorTab.dom.title,
        image: WebInspectorTab.dom.image
    )

    private let elementDescriptor = WebInspectorTab.DisplayDescriptor(
        title: "Element",
        image: UIImage(systemName: "info.circle")
    )

    private enum ContentID {
        static let tree = "tree"
        static let element = "element"
    }

    package func displayItems(for layout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem] {
        switch layout {
        case .compact:
            [.tab(tabID), .domElement(parent: tabID)]
        case .regular:
            [.tab(tabID)]
        }
    }

    package func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            tabID == self.tabID ? descriptor : nil
        case let .domElement(parent):
            parent == tabID ? elementDescriptor : nil
        }
    }

    package func makeViewController(
        for displayItem: WebInspectorTab.DisplayItem,
        context: WebInspectorTab.Context,
        contentStore: PresentationContentStore,
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        return contentStore.domViewController { model in
            makeReadyViewController(
                for: displayItem,
                model: model,
                contentStore: contentStore,
                layout: layout
            )
        }
    }

    private func makeReadyViewController(
        for displayItem: WebInspectorTab.DisplayItem,
        model: DOMPanelModel,
        contentStore: PresentationContentStore,
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        switch (layout, displayItem) {
        case (.compact, .tab):
            DOMCompactNavigationController(
                rootViewController: cachedTreeViewController(
                    model: model,
                    contentStore: contentStore
                ),
                model: model
            )
        case (.compact, .domElement):
            DOMCompactNavigationController(
                rootViewController: cachedElementViewController(
                    model: model,
                    contentStore: contentStore
                )
            )
        case (.regular, _):
            RegularSplitRootViewController(
                contentViewController: DOMSplitViewController(
                    treeViewController: cachedTreeViewController(
                        model: model,
                        contentStore: contentStore
                    ),
                    elementViewController: cachedElementViewController(
                        model: model,
                        contentStore: contentStore
                    ),
                    model: model
                )
            )
        }
    }

    private func cachedTreeViewController(
        model: DOMPanelModel,
        contentStore: PresentationContentStore
    ) -> DOMTreeViewController {
        contentStore.viewController(
            for: contentKey(ContentID.tree)
        ) {
            DOMTreeViewController(model: model)
        }
    }

    private func cachedElementViewController(
        model: DOMPanelModel,
        contentStore: PresentationContentStore
    ) -> DOMElementViewController {
        contentStore.viewController(
            for: contentKey(ContentID.element)
        ) {
            DOMElementViewController(model: model)
        }
    }

    private func contentKey(_ contentID: String) -> WebInspectorTab.ContentKey {
        WebInspectorTab.ContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif

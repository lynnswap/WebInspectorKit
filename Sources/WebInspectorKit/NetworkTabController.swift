#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUINetwork

@MainActor
package struct NetworkTabController {
    package let tabID = WebInspectorTab.network.id
package let descriptor = WebInspectorTab.DisplayDescriptor(
        title: WebInspectorTab.network.title,
        image: WebInspectorTab.network.image
    )

    private enum ContentID {
        static let list = "list"
        static let detail = "detail"
    }

    package func displayItems(
        for layout: WebInspectorTab.HostLayout
    ) -> [WebInspectorTab.DisplayItem] {
        [.tab(tabID)]
    }

    package func descriptor(
        for displayItem: WebInspectorTab.DisplayItem
    ) -> WebInspectorTab.DisplayDescriptor? {
        displayItem == .tab(tabID) ? descriptor : nil
    }

    package func makeViewController(
        for displayItem: WebInspectorTab.DisplayItem,
        context: WebInspectorTab.Context,
        contentStore: PresentationContentStore,
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        return contentStore.networkViewController { model in
            return readyViewController(
                layout: layout,
                contentStore: contentStore,
                model: model
            )
        }
    }

    private func readyViewController(
        layout: WebInspectorTab.HostLayout,
        contentStore: PresentationContentStore,
        model: NetworkPanelModel
    ) -> UIViewController {
        let listViewController = cachedListViewController(
            contentStore: contentStore,
            model: model
        )
        let detailViewController = cachedDetailViewController(
            contentStore: contentStore,
            model: model
        )

        switch layout {
        case .compact:
            return NetworkCompactNavigationController(
                model: model,
                listViewController: listViewController,
                detailViewController: detailViewController
            )
        case .regular:
            return RegularSplitRootViewController(
                contentViewController: NetworkSplitViewController(
                    model: model,
                    listViewController: listViewController,
                    detailViewController: detailViewController
                )
            )
        }
    }

    private func cachedListViewController(
        contentStore: PresentationContentStore,
        model: NetworkPanelModel
    ) -> NetworkListViewController {
        contentStore.viewController(
            for: contentKey(ContentID.list)
        ) {
            NetworkListViewController(model: model)
        }
    }

    private func cachedDetailViewController(
        contentStore: PresentationContentStore,
        model: NetworkPanelModel
    ) -> NetworkDetailViewController {
        contentStore.viewController(
            for: contentKey(ContentID.detail)
        ) {
            NetworkDetailViewController(
                model: model,
                makeBodyViewController: NetworkBodyPreviewFactory.make(scrollEdgeSink:)
            )
        }
    }

    private func contentKey(_ contentID: String) -> WebInspectorTab.ContentKey {
        WebInspectorTab.ContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif

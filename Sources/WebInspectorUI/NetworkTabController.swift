#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUINetwork
import WebInspectorUISyntaxBody

@MainActor
package struct NetworkTabController: WebInspectorTab.BuiltInController {
    package let tabID = WebInspectorTab.network.id
    package let descriptor = WebInspectorTab.DisplayDescriptor(
        title: WebInspectorTab.network.title,
        image: WebInspectorTab.network.image
    )

    private enum ContentID {
        static let list = "list"
        static let detail = "detail"
    }

    package func makeViewController(
        for displayItem: WebInspectorTab.DisplayItem,
        session: WebInspectorSession,
        contentStore: PresentationContentStore,
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        return contentStore.networkViewController(
            context: session.model
        ) { [weak contentStore] model in
            guard let contentStore else {
                preconditionFailure("A Network resource lost its presentation content store.")
            }
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

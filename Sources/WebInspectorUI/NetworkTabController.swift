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

    package func contentKeys(
        for layout: WebInspectorTab.HostLayout,
        displayItem: WebInspectorTab.DisplayItem
    ) -> [WebInspectorTab.ContentKey] {
        [
            contentKey(ContentID.list),
            contentKey(ContentID.detail),
        ]
    }

    package func makeViewController(
        for displayItem: WebInspectorTab.DisplayItem,
        session: WebInspectorSession,
        contentStore: PresentationContentStore,
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        let model = contentStore.networkPanelModel(
            for: session.context,
            contextEpoch: session.interface.contextBoundContentRevision
        )
        let listViewController = cachedListViewController(
            session: session,
            contentStore: contentStore,
            model: model
        )
        let detailViewController = cachedDetailViewController(
            session: session,
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
        session: WebInspectorSession,
        contentStore: PresentationContentStore,
        model: NetworkPanelModel
    ) -> NetworkListViewController {
        contentStore.viewController(
            for: contentKey(ContentID.list),
            contextEpoch: session.interface.contextBoundContentRevision
        ) {
            NetworkListViewController(model: model)
        }
    }

    private func cachedDetailViewController(
        session: WebInspectorSession,
        contentStore: PresentationContentStore,
        model: NetworkPanelModel
    ) -> NetworkDetailViewController {
        contentStore.viewController(
            for: contentKey(ContentID.detail),
            contextEpoch: session.interface.contextBoundContentRevision
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

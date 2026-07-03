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
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        let model = session.interface.networkPanelModel(for: session.context)
        let listViewController = cachedListViewController(session: session, model: model)
        let detailViewController = cachedDetailViewController(session: session, model: model)

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
        model: NetworkPanelModel
    ) -> NetworkListViewController {
        session.interface.viewController(for: contentKey(ContentID.list)) {
            NetworkListViewController(model: model)
        }
    }

    private func cachedDetailViewController(
        session: WebInspectorSession,
        model: NetworkPanelModel
    ) -> NetworkDetailViewController {
        session.interface.viewController(for: contentKey(ContentID.detail)) {
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

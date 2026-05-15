#if canImport(UIKit)
import UIKit

@MainActor
package struct NetworkTabController: BuiltInTabController {
    package let tabID = WebInspectorTab.network.id
    package let descriptor = TabDisplayDescriptor(
        title: WebInspectorTab.network.title,
        image: WebInspectorTab.network.image
    )

    private enum ContentID {
        static let list = "list"
        static let detail = "detail"
    }

    package func contentKeys(
        for layout: WebInspectorTabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey] {
        [
            contentKey(ContentID.list),
            contentKey(ContentID.detail),
        ]
    }

    package func makeViewController(
        for displayItem: TabDisplayItem,
        session: WebInspectorSession,
        layout: WebInspectorTabHostLayout
    ) -> UIViewController {
        let model = session.interface.networkPanelModel(for: session.inspector)
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
            NetworkDetailViewController(model: model)
        }
    }

    private func contentKey(_ contentID: String) -> TabContentKey {
        TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif

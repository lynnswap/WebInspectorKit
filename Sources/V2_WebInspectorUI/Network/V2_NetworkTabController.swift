#if canImport(UIKit)
import UIKit

@MainActor
package struct V2_NetworkTabController: V2_BuiltInTabController {
    package let tabID = V2_WITab.network.id
    package let descriptor = V2_TabDisplayDescriptor(
        title: V2_WITab.network.title,
        image: V2_WITab.network.image
    )

    private enum ContentID {
        static let list = "list"
        static let detail = "detail"
    }

    package func contentKeys(
        for layout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem
    ) -> [V2_TabContentKey] {
        [
            contentKey(ContentID.list),
            contentKey(ContentID.detail),
        ]
    }

    package func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        let model = session.interface.networkPanelModel(for: session.inspector)
        let listViewController = cachedListViewController(session: session, model: model)
        let detailViewController = cachedDetailViewController(session: session, model: model)

        switch layout {
        case .compact:
            return V2_NetworkCompactNavigationController(
                model: model,
                listViewController: listViewController,
                detailViewController: detailViewController
            )
        case .regular:
            return V2_RegularSplitRootViewController(
                contentViewController: V2_NetworkSplitViewController(
                    model: model,
                    listViewController: listViewController,
                    detailViewController: detailViewController
                )
            )
        }
    }

    private func cachedListViewController(
        session: V2_WISession,
        model: V2_NetworkPanelModel
    ) -> V2_NetworkListViewController {
        session.interface.viewController(for: contentKey(ContentID.list)) {
            V2_NetworkListViewController(model: model)
        }
    }

    private func cachedDetailViewController(
        session: V2_WISession,
        model: V2_NetworkPanelModel
    ) -> V2_NetworkDetailViewController {
        session.interface.viewController(for: contentKey(ContentID.detail)) {
            V2_NetworkDetailViewController(model: model)
        }
    }

    private func contentKey(_ contentID: String) -> V2_TabContentKey {
        V2_TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif

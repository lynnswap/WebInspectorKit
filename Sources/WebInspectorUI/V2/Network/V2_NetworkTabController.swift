#if canImport(UIKit)
import UIKit

@MainActor
struct V2_NetworkTabController: V2_BuiltInTabController {
    let tabID = V2_WITab.network.id
    let descriptor = V2_TabDisplayDescriptor(
        title: V2_WITab.network.title,
        image: V2_WITab.network.image
    )

    private enum ContentID {
        static let root = "root"
        static let detail = "detail"
    }

    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem
    ) -> [V2_TabContentKey] {
        [
            contentKey(ContentID.root),
            contentKey(ContentID.detail),
        ]
    }

    func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        let listViewController = cachedNetworkListViewController(session: session)
        let detailViewController = cachedNetworkDetailViewController(session: session)

        switch layout {
        case .compact:
            return V2_NetworkCompactNavigationController(
                inspector: session.runtime.network.model,
                listViewController: listViewController,
                detailViewController: detailViewController
            )
        case .regular:
            return V2_WIRegularSplitRootViewController(
                contentViewController: V2_NetworkSplitViewController(
                    inspector: session.runtime.network.model,
                    listViewController: listViewController,
                    detailViewController: detailViewController
                )
            )
        }
    }

    private func cachedNetworkListViewController(session: V2_WISession) -> V2_NetworkListViewController {
        session.interface.viewController(for: contentKey(ContentID.root)) {
            V2_NetworkListViewController(inspector: session.runtime.network.model)
        }
    }

    private func cachedNetworkDetailViewController(session: V2_WISession) -> V2_NetworkEntryDetailViewController {
        session.interface.viewController(for: contentKey(ContentID.detail)) {
            V2_NetworkEntryDetailViewController(inspector: session.runtime.network.model)
        }
    }

    private func contentKey(_ contentID: String) -> V2_TabContentKey {
        V2_TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif

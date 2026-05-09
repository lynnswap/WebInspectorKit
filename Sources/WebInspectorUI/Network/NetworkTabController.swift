#if canImport(UIKit)
import UIKit

@MainActor
struct NetworkTabController: BuiltInTabController {
    let tabID = WITab.network.id
    let descriptor = TabDisplayDescriptor(
        title: WITab.network.title,
        image: WITab.network.image
    )

    private enum ContentID {
        static let root = "root"
        static let detail = "detail"
    }

    func contentKeys(
        for layout: WITabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey] {
        [
            contentKey(ContentID.root),
            contentKey(ContentID.detail),
        ]
    }

    func makeViewController(
        for displayItem: TabDisplayItem,
        session: WISession,
        layout: WITabHostLayout
    ) -> UIViewController {
        let listViewController = cachedNetworkListViewController(session: session)
        let detailViewController = cachedNetworkDetailViewController(session: session)

        switch layout {
        case .compact:
            return NetworkCompactNavigationController(
                inspector: session.runtime.network.model,
                listViewController: listViewController,
                detailViewController: detailViewController
            )
        case .regular:
            let splitViewController = NetworkSplitViewController(
                inspector: session.runtime.network.model,
                listViewController: listViewController,
                detailViewController: detailViewController
            )
            return WIRegularSplitRootViewController(contentViewController: splitViewController)
        }
    }

    private func cachedNetworkListViewController(session: WISession) -> NetworkListViewController {
        session.interface.viewController(for: contentKey(ContentID.root)) {
            NetworkListViewController(inspector: session.runtime.network.model)
        }
    }

    private func cachedNetworkDetailViewController(session: WISession) -> NetworkEntryDetailViewController {
        session.interface.viewController(for: contentKey(ContentID.detail)) {
            NetworkEntryDetailViewController(inspector: session.runtime.network.model)
        }
    }

    private func contentKey(_ contentID: String) -> TabContentKey {
        TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
struct V2_NetworkTabController: V2_BuiltInTabController {
    let tabID = V2_WITab.network.id
    let descriptor = V2_TabDisplayDescriptor(
        title: V2_WITab.network.title,
        image: V2_WITab.network.image
    )

    func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        let listViewController = session.interface.viewController(
            for: V2_TabContentKey(tabID: tabID, contentID: "root")
        ) {
            V2_NetworkListViewController(inspector: session.runtime.network.model)
        }

        switch layout {
        case .compact:
            return V2_WICompactTabNavigationController(
                rootViewController: listViewController
            )
        case .regular:
            return V2_WIRegularSplitRootViewController(
                contentViewController: V2_NetworkSplitViewController(
                    listViewController: listViewController
                )
            )
        }
    }
}
#endif

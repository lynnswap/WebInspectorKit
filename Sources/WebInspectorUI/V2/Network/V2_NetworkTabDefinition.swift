#if canImport(UIKit)
import UIKit

@MainActor
final class V2_NetworkTabDefinition: V2_WITabDefinition {
    let id = V2_WIStandardTab.network.id
    let title = V2_WIStandardTab.network.title
    let image = V2_WIStandardTab.network.image

    func makeViewController(
        for displayTab: V2_WIDisplayTab,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        let listViewController = session.interface.viewController(
            for: V2_WIDisplayContentKey(definitionID: id, contentID: "root"),
            session: session
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

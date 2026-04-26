#if canImport(UIKit)
import UIKit

@MainActor
struct V2_CustomTabController {
    func makeViewController(
        for tab: V2_WITab,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        guard let custom = tab.custom else {
            return UIViewController()
        }

        let viewController = session.interface.viewController(
            for: V2_TabContentKey(tabID: tab.id, contentID: "root")
        ) {
            custom.makeViewController(V2_WITabProviderContext(session: session))
        }
        guard layout == .regular,
              viewController is UISplitViewController else {
            viewController.wiDetachFromV2ContainerForReuse()
            return viewController
        }
        return V2_WIRegularSplitRootViewController(contentViewController: viewController)
    }
}
#endif

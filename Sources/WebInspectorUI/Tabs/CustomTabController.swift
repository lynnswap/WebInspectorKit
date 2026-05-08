#if canImport(UIKit)
import UIKit

@MainActor
struct CustomTabController {
    func makeViewController(
        for tab: WITab,
        session: WISession
    ) -> UIViewController {
        guard let custom = tab.custom else {
            return UIViewController()
        }

        let viewController = session.interface.viewController(
            for: TabContentKey(tabID: tab.id, contentID: "root")
        ) {
            custom.makeViewController(WITabProviderContext(session: session))
        }
        viewController.wiDetachFromContainerForReuse()
        return viewController
    }
}
#endif

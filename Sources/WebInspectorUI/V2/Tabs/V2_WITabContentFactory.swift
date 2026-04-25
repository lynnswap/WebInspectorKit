#if canImport(UIKit)
import UIKit

enum V2_WITabHostLayout: Hashable {
    case compact
    case regular
}

@MainActor
enum V2_WITabContentFactory {
    static func makeViewController(
        for tab: V2_WITab,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        switch V2_WIStandardTab(id: tab.id) {
        case .some(.dom):
            makeDOMViewController(session: session, hostLayout: hostLayout)
        case .some(.network):
            makeNetworkViewController(hostLayout: hostLayout)
        case nil:
            makeCustomViewController(for: tab, session: session, hostLayout: hostLayout)
        }
    }

    private static func makeDOMViewController(
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        switch hostLayout {
        case .compact:
            V2_WICompactTabNavigationController(
                rootViewController: V2_DOMCompactViewController(session: session)
            )
        case .regular:
            V2_WIRegularSplitRootViewController(
                contentViewController: V2_DOMSplitViewController(session: session)
            )
        }
    }

    private static func makeNetworkViewController(hostLayout: V2_WITabHostLayout) -> UIViewController {
        switch hostLayout {
        case .compact:
            V2_WICompactTabNavigationController(
                rootViewController: V2_NetworkCompactViewController()
            )
        case .regular:
            V2_WIRegularSplitRootViewController(
                contentViewController: V2_NetworkSplitViewController()
            )
        }
    }

    private static func makeCustomViewController(
        for tab: V2_WITab,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        let viewController = tab.makeViewController(session: session)
        guard hostLayout == .regular,
              viewController is UISplitViewController else {
            return viewController
        }
        return V2_WIRegularSplitRootViewController(contentViewController: viewController)
    }
}
#endif

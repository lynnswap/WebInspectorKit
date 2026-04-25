#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUI

@MainActor
struct V2CompactTabBarControllerTests {
    @Test
    func providedCompactTabsUseNavigationControllers() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)

        let domViewController = V2_WITab.dom.makeViewController(session: session, hostLayout: .compact)
        let domNavigationController = try #require(domViewController as? UINavigationController)
        #expect(domNavigationController.viewControllers.first is V2_DOMCompactViewController)
        #expect(domNavigationController.isNavigationBarHidden == false)

        let networkViewController = V2_WITab.network.makeViewController(session: session, hostLayout: .compact)
        let networkNavigationController = try #require(networkViewController as? UINavigationController)
        #expect(networkNavigationController.viewControllers.first is V2_NetworkCompactViewController)
        #expect(networkNavigationController.isNavigationBarHidden == false)
    }

    @Test
    func customCompactTabIsNotForcedIntoNavigationController() {
        let customViewController = UIViewController()
        let tab = V2_WITab(identifier: "custom", title: "Custom") {
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = tab.makeViewController(session: session, hostLayout: .compact)

        #expect(viewController === customViewController)
        #expect((viewController is UINavigationController) == false)
    }
}
#endif

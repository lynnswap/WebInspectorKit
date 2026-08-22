#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUINetwork

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailModeControlControllerTests {
    @Test
    func floatingTabBarUsesUIKitPagingAndPublicTabSelection() throws {
        let controller = NetworkDetailModeControlController(initialMode: .headers)
        let host = UIViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 314, height: 49)
        host.view.addSubview(controller.view)
        let window = showInWindow(host)
        defer { window.isHidden = true }

        var selectedModes: [NetworkDetailViewController.Mode] = []
        controller.selectionHandler = { mode in
            selectedModes.append(mode)
            controller.render(mode: mode, isEnabled: true)
        }
        controller.render(mode: .headers, isEnabled: true)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        #expect(controller.usesFloatingTabBarForTesting)
        let floatingTabBar = try #require(controller.floatingTabBarForTesting)
        let collectionView = try #require(controller.floatingCollectionViewForTesting)
        floatingTabBar.layoutIfNeeded()

        let floatingTabBarClass: AnyClass = try #require(
            NSClassFromString("_UIFloatingTabBar")
        )
        #expect(floatingTabBar.isKind(of: floatingTabBarClass))
        #expect(
            controller.floatingTabTitlesForTesting
                == NetworkDetailViewController.Mode.allCases.map(\.title)
        )
        #expect(controller.selectedFloatingModeForTesting == .headers)
        #expect(controller.floatingTabsAreEnabledForTesting)
        #expect(controller.floatingTabBarShowsSidebarButtonForTesting == false)
        #expect(collectionView.contentSize.width > collectionView.bounds.width)
        #expect(
            descendants(of: floatingTabBar).count {
                NSStringFromClass(type(of: $0)) == "_UIFloatingTabBarPageButton"
            } == 2
        )
        if #available(iOS 26.0, *) {
            #expect(controller.usesExpandedFloatingPaginationForTesting)
            let maximumContainerWidth = try #require(
                controller.floatingMaximumContainerWidthForTesting
            )
            #expect(maximumContainerWidth > floatingTabBar.bounds.width * 0.8)
            #expect(maximumContainerWidth < floatingTabBar.bounds.width)
            #expect(collectionView.bounds.width > 200)
            #expect(controller.floatingTabBarHasLiquidLensForTesting)
        }

        controller.render(mode: .security, isEnabled: true)
        controller.view.layoutIfNeeded()
        #expect(controller.selectedFloatingModeForTesting == .security)

        controller.selectModeForTesting(.cookies)
        #expect(selectedModes == [.cookies])
        #expect(controller.selectedFloatingModeForTesting == .cookies)

        controller.render(mode: .cookies, isEnabled: false)
        #expect(controller.floatingTabsAreEnabledForTesting == false)
        controller.selectModeForTesting(.headers)
        #expect(selectedModes == [.cookies])
        #expect(controller.selectedFloatingModeForTesting == .cookies)
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        viewController.loadViewIfNeeded()
        viewController.view.frame = window.bounds
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { subview in
            [subview] + descendants(of: subview)
        }
    }
}
}
#endif

#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUI

@MainActor
struct V2CompactTabBarControllerTests {
    @Test
    func providedCompactTabsUseNavigationControllers() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)

        let domViewController = V2_WITabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? UINavigationController)
        #expect(domNavigationController.viewControllers.first is V2_DOMTreeViewController)
        #expect(domNavigationController.isNavigationBarHidden == false)

        let networkViewController = V2_WITabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let networkNavigationController = try #require(networkViewController as? UINavigationController)
        #expect(networkNavigationController.viewControllers.first is V2_NetworkCompactViewController)
        #expect(networkNavigationController.isNavigationBarHidden == false)
    }

    @Test
    func compactElementTabUsesElementViewController() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let displayTab = try #require(
            V2_WITabResolver()
                .displayTabs(for: .compact, tabs: session.interface.tabs)
                .first { $0.id == V2_WIDisplayTab.compactElementID }
        )

        let viewController = V2_WITabContentFactory.makeViewController(
            for: displayTab,
            session: session,
            hostLayout: .compact
        )

        let navigationController = try #require(viewController as? UINavigationController)
        #expect(navigationController.viewControllers.first is V2_DOMElementViewController)
    }

    @Test
    func compactDOMTreeDoesNotNestAnotherNavigationController() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let domViewController = V2_WITabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? UINavigationController)
        let treeViewController = try #require(domNavigationController.viewControllers.first)
        #expect(treeViewController is V2_DOMTreeViewController)
        #expect((treeViewController is UINavigationController) == false)
    }

    @Test
    func compactDOMOwnsDOMNavigationItems() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let domViewController = V2_WITabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? UINavigationController)
        let treeViewController = try #require(domNavigationController.viewControllers.first)

        treeViewController.loadViewIfNeeded()

        #expect(treeViewController.navigationItem.additionalOverflowItems != nil)
        #expect(
            treeViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WI.DOM.PickButton" }
        )
    }

    @Test
    func compactTabSelectionUsesNonAnimatedTransition() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let tabBarController = V2_WICompactTabBarController(session: session)
        let animator = try #require(
            tabBarController.tabBarController(
                tabBarController,
                animationControllerForTransitionFrom: UIViewController(),
                to: UIViewController()
            )
        )

        #expect(animator.transitionDuration(using: nil) == 0)
    }

    @Test
    func customCompactTabIsNotForcedIntoNavigationController() {
        let customViewController = UIViewController()
        let tab = V2_WITab(identifier: "custom", title: "Custom") {
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )

        #expect(viewController === customViewController)
        #expect((viewController is UINavigationController) == false)
    }

    @Test
    func customCompactTabCanUseGenericDOMIdentifier() {
        let customViewController = UIViewController()
        let tab = V2_WITab(identifier: "wi_dom", title: "DOM") {
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )

        #expect(viewController === customViewController)
    }

    @Test
    func compactResolverDerivesElementOnlyFromDOMTab() {
        let resolver = V2_WITabResolver()

        #expect(
            resolver.displayTabs(for: .compact, tabs: V2_WITab.defaults).map(\.id)
                == ["wi_dom", "wi_element", "wi_network"]
        )
        #expect(
            resolver.displayTabs(for: .compact, tabs: [.network]).map(\.id)
                == ["wi_network"]
        )
    }
}
#endif

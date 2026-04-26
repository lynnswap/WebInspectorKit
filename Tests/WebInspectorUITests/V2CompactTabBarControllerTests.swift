#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUI

@MainActor
struct V2CompactTabBarControllerTests {
    @Test
    func providedCompactTabsUseNavigationControllers() throws {
        let session = V2_WISession(tabs: [.dom, .network])

        let domViewController = V2_TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? UINavigationController)
        #expect(domNavigationController.viewControllers.first is V2_DOMTreeViewController)
        #expect(domNavigationController.isNavigationBarHidden == false)

        let networkViewController = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let networkNavigationController = try #require(networkViewController as? UINavigationController)
        #expect(networkNavigationController.viewControllers.first is V2_NetworkListViewController)
        #expect(networkNavigationController.isNavigationBarHidden == false)
    }

    @Test
    func compactElementTabUsesElementViewController() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let displayTab = try #require(
            V2_TabDisplayProjection()
                .displayItems(for: .compact, tabs: session.interface.tabs)
                .first { $0.id == V2_TabDisplayItem.domElementID }
        )

        let viewController = V2_TabContentFactory.makeViewController(
            for: displayTab,
            session: session,
            hostLayout: .compact
        )

        let navigationController = try #require(viewController as? UINavigationController)
        #expect(navigationController.viewControllers.first is V2_DOMElementViewController)
    }

    @Test
    func compactDOMTreeDoesNotNestAnotherNavigationController() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let domViewController = V2_TabContentFactory.makeViewController(
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
        let session = V2_WISession(tabs: [.dom, .network])
        let domViewController = V2_TabContentFactory.makeViewController(
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
    func compactNetworkOwnsNetworkNavigationItems() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let networkViewController = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let networkNavigationController = try #require(networkViewController as? UINavigationController)
        let listViewController = try #require(
            networkNavigationController.viewControllers.first as? V2_NetworkListViewController
        )

        listViewController.loadViewIfNeeded()

        #expect(listViewController.navigationItem.additionalOverflowItems != nil)
        #expect(listViewController.navigationItem.searchController != nil)
        #expect(
            listViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WI.Network.FilterButton" }
        )
    }

    @Test
    func compactTabSelectionUsesNonAnimatedTransition() throws {
        let session = V2_WISession(tabs: [.dom, .network])
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
        let tab = V2_WITab.custom(id: "custom", title: "Custom", image: nil) { _ in
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = V2_TabContentFactory.makeViewController(
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
        let tab = V2_WITab.custom(id: "wi_dom", title: "DOM", image: nil) { _ in
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = V2_TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )

        #expect(viewController === customViewController)
    }

    @Test
    func compactResolverDerivesElementOnlyFromDOMTab() {
        let resolver = V2_TabDisplayProjection()

        #expect(
            resolver.displayItems(for: .compact, tabs: [.dom, .network]).map(\.id)
                == ["wi_dom", V2_TabDisplayItem.domElementID, "wi_network"]
        )
        #expect(
            resolver.displayItems(for: .compact, tabs: [.network]).map(\.id)
                == ["wi_network"]
        )
    }
}
#endif

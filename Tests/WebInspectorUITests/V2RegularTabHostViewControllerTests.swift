#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUI

@MainActor
struct V2RegularTabHostViewControllerTests {
    @Test
    func regularHostWrapsSplitTabBeforeInstallingInNavigationStack() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController is UISplitViewController == false)
        #expect(rootViewController.children.contains { $0 is UISplitViewController })
        #expect(rootViewController.navigationItem.centerItemGroups.isEmpty == false)
    }

    @Test
    func domSplitOwnsDOMNavigationItems() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let splitViewController = V2_DOMSplitViewController(session: session)

        splitViewController.loadViewIfNeeded()

        #expect(splitViewController.navigationItem.additionalOverflowItems != nil)
        #expect(
            splitViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WI.DOM.PickButton" }
        )
    }

    @Test
    func regularDOMSplitNavigationItemsAreExposedThroughRoot() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.navigationItem.additionalOverflowItems != nil)
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WI.DOM.PickButton" }
        )
    }

    @Test
    func regularNetworkRootDoesNotExposeDOMNavigationItems() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        session.interface.selectTab(V2_WITab.network)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.navigationItem.additionalOverflowItems == nil)
        #expect(rootViewController.navigationItem.trailingItemGroups.isEmpty)
    }

    @Test
    func regularDOMSplitColumnsUseHiddenNavigationControllers() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)

        try assertHiddenNavigationControllers(in: splitViewController, columns: domColumns)
    }

    @Test
    func regularNetworkSplitColumnsUseHiddenNavigationControllers() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        session.interface.selectTab(V2_WITab.network)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)

        try assertHiddenNavigationControllers(in: splitViewController, columns: [.primary, .secondary])
    }

    @Test
    func customRegularTabCanUseGenericNetworkIdentifier() {
        let customViewController = UIViewController()
        let tab = V2_WITab(identifier: "network", title: "Network") {
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .regular
        )

        #expect(viewController === customViewController)
    }

    private var domColumns: [UISplitViewController.Column] {
        if #available(iOS 26.0, *) {
            [.secondary, .inspector]
        } else {
            [.primary, .secondary]
        }
    }

    private func assertHiddenNavigationControllers(
        in splitViewController: UISplitViewController,
        columns: [UISplitViewController.Column]
    ) throws {
        for column in columns {
            let viewController = try #require(splitViewController.viewController(for: column))
            let navigationController = try #require(viewController as? UINavigationController)
            #expect(navigationController.isNavigationBarHidden)
        }
    }
}
#endif

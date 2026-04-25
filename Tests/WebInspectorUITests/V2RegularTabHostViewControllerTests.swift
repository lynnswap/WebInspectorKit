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
        session.interface.selectTab("network")
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)

        try assertHiddenNavigationControllers(in: splitViewController, columns: [.primary, .secondary])
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

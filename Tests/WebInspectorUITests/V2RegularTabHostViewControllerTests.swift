#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorRuntime
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
        let dom = V2_WIDOMRuntime()
        let splitViewController = V2_DOMSplitViewController(
            dom: dom,
            treeViewController: V2_DOMTreeViewController(dom: dom),
            elementViewController: V2_DOMElementViewController(dom: dom)
        )

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
    func regularNetworkRootDoesNotExposeNetworkListNavigationItems() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        session.interface.selectTab(V2_WITab.network)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.navigationItem.searchController == nil)
        #expect(rootViewController.navigationItem.additionalOverflowItems == nil)
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains {
                    $0.accessibilityIdentifier == "WI.Network.FilterButton"
                        || $0.accessibilityIdentifier == "WI.DOM.PickButton"
                } == false
        )
    }

    @Test
    func regularNetworkListColumnOwnsNetworkNavigationItems() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        session.interface.selectTab(V2_WITab.network)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)
        let navigationController = try #require(splitViewController.viewController(for: .primary) as? UINavigationController)
        let listViewController = try #require(
            navigationController.viewControllers.first as? V2_NetworkListViewController
        )

        listViewController.loadViewIfNeeded()

        #expect(listViewController.navigationItem.searchController != nil)
        #expect(listViewController.navigationItem.additionalOverflowItems != nil)
        #expect(
            listViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WI.Network.FilterButton" }
        )
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
    func regularNetworkSplitShowsListColumnNavigationOnly() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        session.interface.selectTab(V2_WITab.network)
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)

        let primaryNavigationController = try #require(
            splitViewController.viewController(for: .primary) as? UINavigationController
        )
        #expect(primaryNavigationController.isNavigationBarHidden == false)
        try assertHiddenNavigationControllers(in: splitViewController, columns: [.secondary])
    }

    @Test
    func customRegularTabCanUseGenericNetworkIdentifier() {
        let customViewController = UIViewController()
        let tab = V2_WITab(identifier: "wi_network", title: "Network") {
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

    @Test
    func regularResolverDoesNotExposeCompactElement() {
        let resolver = V2_WITabResolver()

        #expect(
            resolver.displayTabs(for: .regular, tabs: V2_WITab.defaults).map(\.id)
                == ["wi_dom", "wi_network"]
        )
    }

    @Test
    func compactElementSelectionFallsBackToDOMInRegularWithoutMutatingSelection() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        session.interface.selectDisplayTab(withID: V2_WIDisplayTab.compactElementID)

        let selectedDisplayTab = V2_WITabResolver().selectedDisplayTab(
            for: .regular,
            tabs: session.interface.tabs,
            selection: session.interface.selection
        )

        #expect(selectedDisplayTab?.id == V2_WITab.dom.id)
        #expect(session.interface.selection == V2_WIDisplayTab.compactElementID)
    }

    @Test
    func domContentViewControllersAreSharedBetweenCompactAndRegular() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let compactDOMNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: .dom,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactTreeViewController = try #require(
            compactDOMNavigationController.viewControllers.first as? V2_DOMTreeViewController
        )
        let elementDisplayTab = try #require(
            V2_WITabResolver()
                .displayTabs(for: .compact, tabs: session.interface.tabs)
                .first { $0.id == V2_WIDisplayTab.compactElementID }
        )
        let compactElementNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: elementDisplayTab,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactElementViewController = try #require(
            compactElementNavigationController.viewControllers.first as? V2_DOMElementViewController
        )

        let regularRootViewController = V2_WITabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: regularRootViewController)

        #expect(try splitRootViewController(in: splitViewController, column: domTreeColumn) === compactTreeViewController)
        #expect(try splitRootViewController(in: splitViewController, column: domElementColumn) === compactElementViewController)
    }

    @Test
    func networkListViewControllerIsSharedBetweenCompactAndRegular() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let compactNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactListViewController = try #require(
            compactNavigationController.viewControllers.first as? V2_NetworkListViewController
        )

        let regularRootViewController = V2_WITabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: regularRootViewController)
        let regularListViewController: V2_NetworkListViewController = try splitRootViewController(
            in: splitViewController,
            column: .primary
        )

        #expect(regularListViewController === compactListViewController)
    }

    @Test
    func customProviderIsCalledOncePerCachedTab() {
        let customViewController = UIViewController()
        var providerCallCount = 0
        let tab = V2_WITab(identifier: "custom", title: "Custom") {
            providerCallCount += 1
            return customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let compactViewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )
        let regularViewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .regular
        )

        #expect(providerCallCount == 1)
        #expect(compactViewController === customViewController)
        #expect(regularViewController === customViewController)
    }

    @Test
    func cachedCustomContentDetachesFromPreviousParentBeforeReuse() {
        let customViewController = UIViewController()
        let tab = V2_WITab(identifier: "custom", title: "Custom") {
            customViewController
        }
        let session = V2_WISession(tabs: [tab])
        let compactViewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )
        let previousNavigationController = UINavigationController(rootViewController: compactViewController)

        let regularViewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .regular
        )

        #expect(regularViewController === customViewController)
        #expect(customViewController.parent == nil)
        #expect(previousNavigationController.viewControllers.isEmpty)
    }

    @Test
    func changingTabsPrunesUnreachableContentCache() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let compactNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let cachedNetworkListViewController = try #require(compactNavigationController.viewControllers.first)

        session.interface.setTabs([.dom])
        let networkKey = V2_WIDisplayContentKey(
            definitionID: V2_WITab.network.id,
            contentID: "root"
        )
        let replacementViewController = session.interface.viewController(for: networkKey, session: session) {
            UIViewController()
        }

        #expect(replacementViewController !== cachedNetworkListViewController)
    }

    @Test
    func sharedInterfaceKeepsContentCacheScopedBySession() throws {
        let interface = V2_WIInterfaceModel(tabs: V2_WITab.defaults)
        let firstSession = V2_WISession(interface: interface)
        let secondSession = V2_WISession(interface: interface)

        let firstNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: .network,
                session: firstSession,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let firstListViewController = try #require(
            firstNavigationController.viewControllers.first as? V2_NetworkListViewController
        )

        let secondNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: .network,
                session: secondSession,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let secondListViewController = try #require(
            secondNavigationController.viewControllers.first as? V2_NetworkListViewController
        )

        #expect(secondListViewController !== firstListViewController)
    }

    @Test
    func cachedContentParentMovesToCurrentContainer() throws {
        let session = V2_WISession(tabs: V2_WITab.defaults)
        let firstRegularRootViewController = V2_WITabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        let firstSplitViewController = try childSplitViewController(in: firstRegularRootViewController)
        let treeViewController: V2_DOMTreeViewController = try splitRootViewController(
            in: firstSplitViewController,
            column: domTreeColumn
        )
        let firstParent = try #require(treeViewController.parent)

        let compactNavigationController = try #require(
            V2_WITabContentFactory.makeViewController(
                for: .dom,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactTreeViewController = try #require(compactNavigationController.viewControllers.first)

        #expect(compactTreeViewController === treeViewController)
        #expect(treeViewController.parent === compactNavigationController)
        #expect(treeViewController.parent !== firstParent)

        let secondRegularRootViewController = V2_WITabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        let secondSplitViewController = try childSplitViewController(in: secondRegularRootViewController)
        let secondRegularTreeViewController: V2_DOMTreeViewController = try splitRootViewController(
            in: secondSplitViewController,
            column: domTreeColumn
        )

        #expect(secondRegularTreeViewController === treeViewController)
        #expect(treeViewController.parent is V2_WIRegularSplitColumnNavigationController)
    }

    @Test
    func cachedDOMTreeRefreshesWebViewAfterRuntimeDetach() async throws {
        let runtime = V2_WIDOMRuntime()
        let treeViewController = V2_DOMTreeViewController(dom: runtime)
        treeViewController.loadViewIfNeeded()

        treeViewController.beginAppearanceTransition(true, animated: false)
        treeViewController.endAppearanceTransition()
        let firstWebView = try #require(treeViewController.displayedDOMTreeWebViewForTesting)

        await runtime.detach()

        treeViewController.beginAppearanceTransition(true, animated: false)
        treeViewController.endAppearanceTransition()
        let secondWebView = try #require(treeViewController.displayedDOMTreeWebViewForTesting)

        #expect(secondWebView !== firstWebView)
        #expect(secondWebView.superview === treeViewController.view)
        #expect(firstWebView.superview == nil)
    }

    private var domColumns: [UISplitViewController.Column] {
        if #available(iOS 26.0, *) {
            [.secondary, .inspector]
        } else {
            [.primary, .secondary]
        }
    }

    private var domTreeColumn: UISplitViewController.Column {
        if #available(iOS 26.0, *) {
            .secondary
        } else {
            .primary
        }
    }

    private var domElementColumn: UISplitViewController.Column {
        if #available(iOS 26.0, *) {
            .inspector
        } else {
            .secondary
        }
    }

    private func childSplitViewController(in viewController: UIViewController) throws -> UISplitViewController {
        viewController.loadViewIfNeeded()
        return try #require(viewController.children.first as? UISplitViewController)
    }

    private func splitRootViewController<T: UIViewController>(
        in splitViewController: UISplitViewController,
        column: UISplitViewController.Column
    ) throws -> T {
        let navigationController = try #require(splitViewController.viewController(for: column) as? UINavigationController)
        return try #require(navigationController.viewControllers.first as? T)
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

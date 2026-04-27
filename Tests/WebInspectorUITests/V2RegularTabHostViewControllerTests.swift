#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct V2RegularTabHostViewControllerTests {
    @Test
    func regularHostWrapsSplitTabBeforeInstallingInNavigationStack() throws {
        let session = V2_WISession(tabs: [.dom, .network])
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
        let session = V2_WISession(tabs: [.dom, .network])
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
        let session = V2_WISession(tabs: [.dom, .network])
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
        let session = V2_WISession(tabs: [.dom, .network])
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
    func regularNetworkSplitContainsDetailSecondary() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.interface.selectTab(V2_WITab.network)
        let rootViewController = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: rootViewController)
        let detailViewController: V2_NetworkEntryDetailViewController = try splitRootViewController(
            in: splitViewController,
            column: .secondary
        )

        #expect(detailViewController.collectionViewForTesting.isHidden)
    }

    @Test
    func regularNetworkListSelectionUpdatesDetailSecondary() async throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.interface.selectTab(V2_WITab.network)
        let entry = try #require(
            session.runtime.network.model.store.applySnapshots([
                makeSnapshot(requestID: 1, url: "https://example.com/detail.json")
            ]).first
        )
        let rootViewController = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let window = showInWindow(rootViewController)
        defer { window.isHidden = true }
        let splitViewController = try childSplitViewController(in: rootViewController)
        let listViewController: V2_NetworkListViewController = try splitRootViewController(
            in: splitViewController,
            column: .primary
        )
        let detailViewController: V2_NetworkEntryDetailViewController = try splitRootViewController(
            in: splitViewController,
            column: .secondary
        )

        let collectionView = listViewController.collectionViewForTesting
        let didRenderList = await waitUntil {
            collectionView.numberOfSections == 1 && collectionView.numberOfItems(inSection: 0) == 1
        }
        #expect(didRenderList)

        listViewController.collectionView(collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))

        let didUpdateDetail = await waitUntil {
            session.runtime.network.model.selectedEntry === entry
                && detailViewController.collectionViewForTesting.isHidden == false
        }

        #expect(didUpdateDetail)
    }

    @Test
    func regularDOMSplitColumnsUseHiddenNavigationControllers() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let host = V2_WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)

        try assertHiddenNavigationControllers(in: splitViewController, columns: domColumns)
    }

    @Test
    func regularNetworkSplitShowsListColumnNavigationOnly() throws {
        let session = V2_WISession(tabs: [.dom, .network])
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
    func regularHostRestoresPreviouslySelectedNetworkTab() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.interface.selectTab(.network)

        let host = V2_WIRegularTabContentViewController(session: session)
        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try childSplitViewController(in: rootViewController)
        let navigationController = try #require(splitViewController.viewController(for: .primary) as? UINavigationController)

        #expect(navigationController.viewControllers.first is V2_NetworkListViewController)
        #expect(session.interface.selectedItemID == V2_WITab.network.id)
    }

    @Test
    func compactHostRestoresSelectionAfterRegularHostDisplaysNetwork() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.interface.selectTab(.network)

        let regularHost = V2_WIRegularTabContentViewController(session: session)
        regularHost.loadViewIfNeeded()
        let compactHost = V2_WICompactTabBarController(session: session)
        compactHost.loadViewIfNeeded()

        #expect(compactHost.selectedTab?.identifier == V2_WITab.network.id)
        #expect(session.interface.selectedItemID == V2_WITab.network.id)
    }

    @Test
    func compactElementSelectionSurvivesRegularRoundTrip() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.interface.selectItem(withID: V2_TabDisplayItem.domElementID)

        let regularHost = V2_WIRegularTabContentViewController(session: session)
        regularHost.loadViewIfNeeded()
        let compactHost = V2_WICompactTabBarController(session: session)
        compactHost.loadViewIfNeeded()

        #expect(compactHost.selectedTab?.identifier == V2_TabDisplayItem.domElementID)
        #expect(session.interface.selectedItemID == V2_TabDisplayItem.domElementID)
    }

    @Test
    func customRegularTabCanUseGenericNetworkIdentifier() {
        let customViewController = UIViewController()
        let tab = V2_WITab.custom(id: "wi_network", title: "Network", image: nil) { _ in
            customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let viewController = V2_TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .regular
        )

        #expect(viewController === customViewController)
    }

    @Test
    func regularResolverDoesNotExposeCompactElement() {
        let resolver = V2_TabDisplayProjection()

        #expect(
            resolver.displayItems(for: .regular, tabs: [.dom, .network]).map(\.id)
                == ["wi_dom", "wi_network"]
        )
    }

    @Test
    func compactElementSelectionFallsBackToDOMInRegularWithoutMutatingSelection() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.interface.selectItem(withID: V2_TabDisplayItem.domElementID)

        let selectedDisplayTab = V2_TabDisplayProjection().resolvedSelection(
            for: .regular,
            tabs: session.interface.tabs,
            selectedItemID: session.interface.selectedItemID
        )

        #expect(selectedDisplayTab?.id == V2_WITab.dom.id)
        #expect(session.interface.selectedItemID == V2_TabDisplayItem.domElementID)
    }

    @Test
    func domContentViewControllersAreSharedBetweenCompactAndRegular() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let compactDOMNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .dom,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactTreeViewController = try #require(
            compactDOMNavigationController.viewControllers.first as? V2_DOMTreeViewController
        )
        let elementDisplayTab = try #require(
            V2_TabDisplayProjection()
                .displayItems(for: .compact, tabs: session.interface.tabs)
                .first { $0.id == V2_TabDisplayItem.domElementID }
        )
        let compactElementNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: elementDisplayTab,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactElementViewController = try #require(
            compactElementNavigationController.viewControllers.first as? V2_DOMElementViewController
        )

        let regularRootViewController = V2_TabContentFactory.makeViewController(
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
        let session = V2_WISession(tabs: [.dom, .network])
        let compactNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactListViewController = try #require(
            compactNavigationController.viewControllers.first as? V2_NetworkListViewController
        )

        let regularRootViewController = V2_TabContentFactory.makeViewController(
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
    func networkDetailViewControllerIsSharedBetweenCompactAndRegular() async throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.runtime.network.model.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/detail.json")
        ])
        let compactNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactListViewController = try #require(
            compactNavigationController.viewControllers.first as? V2_NetworkListViewController
        )
        let window = showInWindow(compactNavigationController)
        defer { window.isHidden = true }

        let collectionView = compactListViewController.collectionViewForTesting
        let didRenderList = await waitUntil {
            collectionView.numberOfSections == 1 && collectionView.numberOfItems(inSection: 0) == 1
        }
        #expect(didRenderList)

        compactListViewController.collectionView(collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))
        let didPushDetail = await waitUntil {
            compactNavigationController.viewControllers.last is V2_NetworkEntryDetailViewController
        }
        #expect(didPushDetail)

        let compactDetailViewController = try #require(
            compactNavigationController.viewControllers.last as? V2_NetworkEntryDetailViewController
        )

        let regularRootViewController = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: regularRootViewController)
        let regularDetailViewController: V2_NetworkEntryDetailViewController = try splitRootViewController(
            in: splitViewController,
            column: .secondary
        )

        #expect(regularDetailViewController === compactDetailViewController)
    }

    @Test
    func customProviderIsCalledOncePerCachedTab() {
        let customViewController = UIViewController()
        var providerCallCount = 0
        let tab = V2_WITab.custom(id: "custom", title: "Custom", image: nil) { _ in
            providerCallCount += 1
            return customViewController
        }
        let session = V2_WISession(tabs: [tab])

        let compactViewController = V2_TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )
        let regularViewController = V2_TabContentFactory.makeViewController(
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
        let tab = V2_WITab.custom(id: "custom", title: "Custom", image: nil) { _ in
            customViewController
        }
        let session = V2_WISession(tabs: [tab])
        let compactViewController = V2_TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )
        let previousNavigationController = UINavigationController(rootViewController: compactViewController)

        let regularViewController = V2_TabContentFactory.makeViewController(
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
        let session = V2_WISession(tabs: [.dom, .network])
        let compactNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let cachedNetworkListViewController = try #require(compactNavigationController.viewControllers.first)

        session.interface.setTabs([.dom])
        let networkKey = V2_TabContentKey(
            tabID: V2_WITab.network.id,
            contentID: "root"
        )
        let replacementViewController = session.interface.viewController(for: networkKey) {
            UIViewController()
        }

        #expect(replacementViewController !== cachedNetworkListViewController)
    }

    @Test
    func contentCacheIsScopedBySession() throws {
        let firstSession = V2_WISession(tabs: [.dom, .network])
        let secondSession = V2_WISession(tabs: [.dom, .network])

        let firstNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: firstSession,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let firstListViewController = try #require(
            firstNavigationController.viewControllers.first as? V2_NetworkListViewController
        )

        let secondNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
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
        let session = V2_WISession(tabs: [.dom, .network])
        let firstRegularRootViewController = V2_TabContentFactory.makeViewController(
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
            V2_TabContentFactory.makeViewController(
                for: .dom,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactTreeViewController = try #require(compactNavigationController.viewControllers.first)

        #expect(compactTreeViewController === treeViewController)
        #expect(treeViewController.parent === compactNavigationController)
        #expect(treeViewController.parent !== firstParent)

        let secondRegularRootViewController = V2_TabContentFactory.makeViewController(
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
        treeViewController.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)

        treeViewController.beginAppearanceTransition(true, animated: false)
        treeViewController.endAppearanceTransition()
        let firstWebView = try #require(treeViewController.displayedDOMTreeWebViewForTesting)
        #expect(firstWebView.frame == treeViewController.view.bounds)

        await runtime.detach()

        treeViewController.beginAppearanceTransition(true, animated: false)
        treeViewController.endAppearanceTransition()
        let secondWebView = try #require(treeViewController.displayedDOMTreeWebViewForTesting)

        #expect(secondWebView !== firstWebView)
        #expect(secondWebView.superview === treeViewController.view)
        #expect(secondWebView.frame == treeViewController.view.bounds)
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

    private func makeSnapshot(
        requestID: Int,
        url: String
    ) -> NetworkEntry.Snapshot {
        NetworkEntry.Snapshot(
            sessionID: "test-session",
            requestID: requestID,
            request: NetworkEntry.Request(
                url: url,
                method: "GET",
                headers: NetworkHeaders(),
                body: nil,
                bodyBytesSent: nil,
                type: nil,
                wallTime: nil
            ),
            response: NetworkEntry.Response(
                statusCode: 200,
                statusText: "OK",
                mimeType: "application/json",
                headers: NetworkHeaders(),
                body: nil,
                blockedCookies: [],
                errorDescription: nil
            ),
            transfer: NetworkEntry.Transfer(
                startTimestamp: 0,
                endTimestamp: 1,
                duration: 1,
                encodedBodyLength: 128,
                decodedBodyLength: 128,
                phase: .completed
            )
        )
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        return window
    }

    private func waitUntil(
        maxTicks: Int = 512,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
#endif

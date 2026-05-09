#if canImport(UIKit)
import SyntaxEditorUI
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct RegularTabHostViewControllerTests {
    @Test
    func regularHostWrapsSplitTabBeforeInstallingInNavigationStack() throws {
        let session = WISession(tabs: [.dom, .network])
        let host = WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController is UISplitViewController == false)
        #expect(rootViewController.children.contains { $0 is UISplitViewController })
        #expect(rootViewController.navigationItem.centerItemGroups.isEmpty == false)
    }

    @Test
    func domSplitOwnsDOMNavigationItems() throws {
        let dom = WIDOMRuntime()
        let splitViewController = DOMSplitViewController(
            dom: dom,
            treeViewController: DOMTreeViewController(dom: dom),
            elementViewController: DOMElementViewController(dom: dom)
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
        let session = WISession(tabs: [.dom, .network])
        let host = WIRegularTabContentViewController(session: session)

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
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let host = WIRegularTabContentViewController(session: session)

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
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let host = WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)
        let navigationController = try #require(splitViewController.viewController(for: .primary) as? UINavigationController)
        let listViewController = try #require(
            navigationController.viewControllers.first as? NetworkListViewController
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
    func regularNetworkRootExposesDetailModeMenuAsTrailingText() async throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let entry = try #require(
            session.runtime.network.model.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/body.json",
                    responseBody: makeBody(full: "{\"ok\":true}", role: .response)
                )
            ]).first
        )
        let host = WIRegularTabContentViewController(session: session)
        let window = showInWindow(host)
        defer { window.isHidden = true }
        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.navigationItem.centerItemGroups.isEmpty == false)
        let initialModeItem = try #require(regularDetailModeItem(in: rootViewController))
        #expect(initialModeItem.isEnabled == false)
        let initialModeButton = try #require(initialModeItem.customView as? UIButton)
        #expect(initialModeButton.configuration?.title == NetworkEntryDetailMode.overview.title)
        #expect(initialModeButton.showsMenuAsPrimaryAction)
        #expect(initialModeButton.changesSelectionAsPrimaryAction)
        #expect(initialModeButton.preferredMenuElementOrder == .fixed)
        #expect(initialModeButton.isEnabled == false)

        session.runtime.network.model.selectEntry(entry)

        let didEnableModeItem = await waitUntil {
            guard
                let modeItem = regularDetailModeItem(in: rootViewController),
                let modeButton = modeItem.customView as? UIButton,
                modeItem.isEnabled,
                modeButton.isEnabled,
                let menu = modeButton.menu,
                let responseAction = action(title: NetworkEntryDetailMode.responseBody.title, in: menu)
            else {
                return false
            }
            return responseAction.attributes.contains(.disabled) == false
        }
        #expect(didEnableModeItem)

        let enabledModeItem = try #require(regularDetailModeItem(in: rootViewController))
        let enabledModeButton = try #require(enabledModeItem.customView as? UIButton)
        #expect(enabledModeItem === initialModeItem)
        #expect(enabledModeButton === initialModeButton)
        #expect(enabledModeButton.preferredMenuElementOrder == .fixed)
        #expect(enabledModeItem.preferredMenuElementOrder == .fixed)
        #expect(menuActionTitles(in: try #require(enabledModeButton.menu)) == NetworkEntryDetailMode.allCases.map(\.title))
        let responseAction = try action(for: .responseBody, in: try #require(enabledModeButton.menu))
        responseAction.performWithSender(nil, target: nil)

        let didSwitchModeTitle = await waitUntil {
            guard
                let modeItem = regularDetailModeItem(in: rootViewController),
                let modeButton = modeItem.customView as? UIButton,
                let menu = modeButton.menu
            else {
                return false
            }
            return modeButton.configuration?.title == NetworkEntryDetailMode.responseBody.title
                && modeButton.preferredMenuElementOrder == .fixed
                && menuActionTitles(in: menu) == NetworkEntryDetailMode.allCases.map(\.title)
        }
        #expect(didSwitchModeTitle)
        let switchedModeItem = try #require(regularDetailModeItem(in: rootViewController))
        let switchedModeButton = try #require(switchedModeItem.customView as? UIButton)
        #expect(switchedModeItem === enabledModeItem)
        #expect(switchedModeButton === enabledModeButton)
    }

    @Test
    func regularNetworkSplitContainsDetailSecondary() throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let rootViewController = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: rootViewController)
        let detailViewController: NetworkEntryDetailViewController = try splitRootViewController(
            in: splitViewController,
            column: .secondary
        )

        #expect(detailViewController.collectionViewForTesting.isHidden)
    }

    @Test
    func regularNetworkListSelectionUpdatesDetailSecondary() async throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let entry = try #require(
            session.runtime.network.model.store.applySnapshots([
                makeSnapshot(requestID: 1, url: "https://example.com/detail.json")
            ]).first
        )
        let rootViewController = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let window = showInWindow(rootViewController)
        defer { window.isHidden = true }
        let splitViewController = try childSplitViewController(in: rootViewController)
        let listViewController: NetworkListViewController = try splitRootViewController(
            in: splitViewController,
            column: .primary
        )
        let detailViewController: NetworkEntryDetailViewController = try splitRootViewController(
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
    func regularNetworkBodyViewUsesDetailSafeArea() async throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let entry = try #require(
            session.runtime.network.model.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/body.json",
                    responseBody: makeBody(
                        full: String(repeating: "{\"ok\":true}", count: 64),
                        role: .response
                    )
                )
            ]).first
        )
        let rootViewController = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let window = showInWindow(
            rootViewController,
            frame: CGRect(x: 0, y: 0, width: 724, height: 560)
        )
        defer { window.isHidden = true }
        let splitViewController = try childSplitViewController(in: rootViewController)
        let detailViewController: NetworkEntryDetailViewController = try splitRootViewController(
            in: splitViewController,
            column: .secondary
        )
        detailViewController.loadViewIfNeeded()
        detailViewController.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 240, bottom: 0, right: 0)
        detailViewController.view.setNeedsLayout()
        detailViewController.view.layoutIfNeeded()

        session.runtime.network.model.selectEntry(entry)
        let collectionView = detailViewController.collectionViewForTesting
        let didRenderOverview = await waitUntil {
            collectionView.isHidden == false
                && collectionView.numberOfSections == 3
        }
        #expect(didRenderOverview)

        detailViewController.setModeForTesting(.responseBody)

        let didRenderBody = await waitUntil {
            detailViewController.bodyTextViewForTesting.text.contains("\"ok\"")
        }
        #expect(didRenderBody)

        let syntaxView = detailViewController.bodyTextViewForTesting
        let syntaxFrame = syntaxView.convert(syntaxView.bounds, to: detailViewController.view)
        let safeAreaFrame = detailViewController.view.safeAreaLayoutGuide.layoutFrame

        #expect(abs(syntaxFrame.minX - safeAreaFrame.minX) <= 1)
        #expect(abs(syntaxFrame.maxX - safeAreaFrame.maxX) <= 1)
    }

    @Test
    func regularDOMSplitColumnsUseHiddenNavigationControllers() throws {
        let session = WISession(tabs: [.dom, .network])
        let host = WIRegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try #require(rootViewController.children.first as? UISplitViewController)

        try assertHiddenNavigationControllers(in: splitViewController, columns: domColumns)
    }

    @Test
    func regularNetworkSplitShowsListColumnNavigationOnly() throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(WITab.network)
        let host = WIRegularTabContentViewController(session: session)

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
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(.network)

        let host = WIRegularTabContentViewController(session: session)
        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()
        let splitViewController = try childSplitViewController(in: rootViewController)
        let navigationController = try #require(splitViewController.viewController(for: .primary) as? UINavigationController)

        #expect(navigationController.viewControllers.first is NetworkListViewController)
        #expect(session.interface.selectedItemID == WITab.network.id)
    }

    @Test
    func compactHostRestoresSelectionAfterRegularHostDisplaysNetwork() throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(.network)

        let regularHost = WIRegularTabContentViewController(session: session)
        regularHost.loadViewIfNeeded()
        let compactHost = WICompactTabBarController(session: session)
        compactHost.loadViewIfNeeded()

        #expect(compactHost.selectedTab?.identifier == WITab.network.id)
        #expect(session.interface.selectedItemID == WITab.network.id)
    }

    @Test
    func compactElementSelectionSurvivesRegularRoundTrip() throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectItem(withID: TabDisplayItem.domElementID)

        let regularHost = WIRegularTabContentViewController(session: session)
        regularHost.loadViewIfNeeded()
        let compactHost = WICompactTabBarController(session: session)
        compactHost.loadViewIfNeeded()

        #expect(compactHost.selectedTab?.identifier == TabDisplayItem.domElementID)
        #expect(session.interface.selectedItemID == TabDisplayItem.domElementID)
    }

    @Test
    func customRegularTabCanUseGenericNetworkIdentifier() {
        let customViewController = UIViewController()
        let tab = WITab.custom(id: "wi_network", title: "Network", image: nil) { _ in
            customViewController
        }
        let session = WISession(tabs: [tab])

        let viewController = TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .regular
        )

        #expect(viewController === customViewController)
    }

    @Test
    func regularResolverDoesNotExposeCompactElement() {
        let resolver = TabDisplayProjection()

        #expect(
            resolver.displayItems(for: .regular, tabs: [.dom, .network]).map(\.id)
                == ["wi_dom", "wi_network"]
        )
    }

    @Test
    func compactElementSelectionFallsBackToDOMInRegularWithoutMutatingSelection() throws {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectItem(withID: TabDisplayItem.domElementID)

        let selectedDisplayTab = TabDisplayProjection().resolvedSelection(
            for: .regular,
            tabs: session.interface.tabs,
            selectedItemID: session.interface.selectedItemID
        )

        #expect(selectedDisplayTab?.id == WITab.dom.id)
        #expect(session.interface.selectedItemID == TabDisplayItem.domElementID)
    }

    @Test
    func domContentViewControllersAreSharedBetweenCompactAndRegular() throws {
        let session = WISession(tabs: [.dom, .network])
        let compactDOMNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .dom,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactTreeViewController = try #require(
            compactDOMNavigationController.viewControllers.first as? DOMTreeViewController
        )
        let elementDisplayTab = try #require(
            TabDisplayProjection()
                .displayItems(for: .compact, tabs: session.interface.tabs)
                .first { $0.id == TabDisplayItem.domElementID }
        )
        let compactElementNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: elementDisplayTab,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactElementViewController = try #require(
            compactElementNavigationController.viewControllers.first as? DOMElementViewController
        )

        let regularRootViewController = TabContentFactory.makeViewController(
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
        let session = WISession(tabs: [.dom, .network])
        let compactNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactListViewController = try #require(
            compactNavigationController.viewControllers.first as? NetworkListViewController
        )

        let regularRootViewController = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: regularRootViewController)
        let regularListViewController: NetworkListViewController = try splitRootViewController(
            in: splitViewController,
            column: .primary
        )

        #expect(regularListViewController === compactListViewController)
    }

    @Test
    func networkDetailViewControllerIsSharedBetweenCompactAndRegular() async throws {
        let session = WISession(tabs: [.dom, .network])
        session.runtime.network.model.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/detail.json")
        ])
        let compactNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactListViewController = try #require(
            compactNavigationController.viewControllers.first as? NetworkListViewController
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
            compactNavigationController.viewControllers.last is NetworkEntryDetailViewController
        }
        #expect(didPushDetail)

        let compactDetailViewController = try #require(
            compactNavigationController.viewControllers.last as? NetworkEntryDetailViewController
        )

        let regularRootViewController = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let splitViewController = try childSplitViewController(in: regularRootViewController)
        let regularDetailViewController: NetworkEntryDetailViewController = try splitRootViewController(
            in: splitViewController,
            column: .secondary
        )

        #expect(regularDetailViewController === compactDetailViewController)
    }

    @Test
    func customProviderIsCalledOncePerCachedTab() {
        let customViewController = UIViewController()
        var providerCallCount = 0
        let tab = WITab.custom(id: "custom", title: "Custom", image: nil) { _ in
            providerCallCount += 1
            return customViewController
        }
        let session = WISession(tabs: [tab])

        let compactViewController = TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )
        let regularViewController = TabContentFactory.makeViewController(
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
        let tab = WITab.custom(id: "custom", title: "Custom", image: nil) { _ in
            customViewController
        }
        let session = WISession(tabs: [tab])
        let compactViewController = TabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .compact
        )
        let previousNavigationController = UINavigationController(rootViewController: compactViewController)

        let regularViewController = TabContentFactory.makeViewController(
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
        let session = WISession(tabs: [.dom, .network])
        let compactNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let cachedNetworkListViewController = try #require(compactNavigationController.viewControllers.first)

        session.interface.setTabs([.dom])
        let networkKey = TabContentKey(
            tabID: WITab.network.id,
            contentID: "root"
        )
        let replacementViewController = session.interface.viewController(for: networkKey) {
            UIViewController()
        }

        #expect(replacementViewController !== cachedNetworkListViewController)
    }

    @Test
    func contentCacheIsScopedBySession() throws {
        let firstSession = WISession(tabs: [.dom, .network])
        let secondSession = WISession(tabs: [.dom, .network])

        let firstNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .network,
                session: firstSession,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let firstListViewController = try #require(
            firstNavigationController.viewControllers.first as? NetworkListViewController
        )

        let secondNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .network,
                session: secondSession,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let secondListViewController = try #require(
            secondNavigationController.viewControllers.first as? NetworkListViewController
        )

        #expect(secondListViewController !== firstListViewController)
    }

    @Test
    func cachedContentParentMovesToCurrentContainer() throws {
        let session = WISession(tabs: [.dom, .network])
        let firstRegularRootViewController = TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        let firstSplitViewController = try childSplitViewController(in: firstRegularRootViewController)
        let treeViewController: DOMTreeViewController = try splitRootViewController(
            in: firstSplitViewController,
            column: domTreeColumn
        )
        let firstParent = try #require(treeViewController.parent)

        let compactNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .dom,
                session: session,
                hostLayout: .compact
            ) as? UINavigationController
        )
        let compactTreeViewController = try #require(compactNavigationController.viewControllers.first)

        #expect(compactTreeViewController === treeViewController)
        #expect(treeViewController.parent === compactNavigationController)
        #expect(treeViewController.parent !== firstParent)

        let secondRegularRootViewController = TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        let secondSplitViewController = try childSplitViewController(in: secondRegularRootViewController)
        let secondRegularTreeViewController: DOMTreeViewController = try splitRootViewController(
            in: secondSplitViewController,
            column: domTreeColumn
        )

        #expect(secondRegularTreeViewController === treeViewController)
        #expect(treeViewController.parent is WIRegularSplitColumnNavigationController)
    }

    @Test
    func cachedDOMTreeRefreshesWebViewAfterRuntimeDetach() async throws {
        let runtime = WIDOMRuntime()
        let treeViewController = DOMTreeViewController(dom: runtime)
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
        url: String,
        requestBody: NetworkBody? = nil,
        responseBody: NetworkBody? = nil
    ) -> NetworkEntry.Snapshot {
        NetworkEntry.Snapshot(
            sessionID: "test-session",
            requestID: requestID,
            request: NetworkEntry.Request(
                url: url,
                method: "GET",
                headers: NetworkHeaders(),
                body: requestBody,
                bodyBytesSent: nil,
                type: nil,
                wallTime: nil
            ),
            response: NetworkEntry.Response(
                statusCode: 200,
                statusText: "OK",
                mimeType: "application/json",
                headers: NetworkHeaders(),
                body: responseBody,
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

    private func makeBody(
        full: String,
        role: NetworkBody.Role
    ) -> NetworkBody {
        NetworkBody(
            kind: .text,
            preview: full,
            full: full,
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: nil,
            reference: nil,
            formEntries: [],
            fetchState: .full,
            role: role
        )
    }

    private func regularDetailModeItem(in viewController: UIViewController) -> UIBarButtonItem? {
        viewController.navigationItem.trailingItemGroups
            .flatMap(\.barButtonItems)
            .first { $0.accessibilityIdentifier == "WebInspector.Network.DetailModeButton.Regular" }
    }

    private func action(
        for mode: NetworkEntryDetailMode,
        in menu: UIMenu
    ) throws -> UIAction {
        try #require(action(title: mode.title, in: menu))
    }

    private func action(title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title {
                return action
            }
            if let submenu = child as? UIMenu, let nested = action(title: title, in: submenu) {
                return nested
            }
        }
        return nil
    }

    private func menuActionTitles(in menu: UIMenu) -> [String] {
        menu.children.compactMap { ($0 as? UIAction)?.title }
    }

    private func showInWindow(
        _ viewController: UIViewController,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1024, height: 768)
    ) -> UIWindow {
        let window = UIWindow(frame: frame)
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

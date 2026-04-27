#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
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
    func compactNetworkSelectionPushesDetailViewController() async throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let entries = session.runtime.network.model.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/request.json")
        ])
        let entry = try #require(entries.first)
        let networkNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? V2_NetworkCompactNavigationController
        )
        let listViewController = try #require(
            networkNavigationController.viewControllers.first as? V2_NetworkListViewController
        )
        let window = showInWindow(networkNavigationController)
        defer { window.isHidden = true }

        let collectionView = listViewController.collectionViewForTesting
        let didRenderList = await waitUntil {
            collectionView.numberOfSections == 1 && collectionView.numberOfItems(inSection: 0) == 1
        }
        #expect(didRenderList)

        listViewController.collectionView(collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))

        let didPushDetail = await waitUntil {
            networkNavigationController.viewControllers.last is V2_NetworkEntryDetailViewController
        }

        #expect(didPushDetail)
        #expect(session.runtime.network.model.selectedEntry === entry)
    }

    @Test
    func compactNetworkModelSelectionDoesNotPushDetailViewController() throws {
        let session = V2_WISession(tabs: [.dom, .network])
        let entry = try #require(
            session.runtime.network.model.store.applySnapshots([
                makeSnapshot(requestID: 1, url: "https://example.com/request.json")
            ]).first
        )
        let networkNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? V2_NetworkCompactNavigationController
        )

        session.runtime.network.model.selectEntry(entry)

        #expect(networkNavigationController.viewControllers.last is V2_NetworkListViewController)
    }

    @Test
    func compactNetworkBackFromDetailClearsSelection() async throws {
        let session = V2_WISession(tabs: [.dom, .network])
        session.runtime.network.model.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/request.json")
        ])
        let networkNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? V2_NetworkCompactNavigationController
        )
        let listViewController = try #require(
            networkNavigationController.viewControllers.first as? V2_NetworkListViewController
        )
        let window = showInWindow(networkNavigationController)
        defer { window.isHidden = true }

        let collectionView = listViewController.collectionViewForTesting
        let didRenderList = await waitUntil {
            collectionView.numberOfSections == 1 && collectionView.numberOfItems(inSection: 0) == 1
        }
        #expect(didRenderList)

        listViewController.collectionView(collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))
        let didPushDetail = await waitUntil {
            networkNavigationController.viewControllers.last is V2_NetworkEntryDetailViewController
        }
        #expect(didPushDetail)

        _ = networkNavigationController.popToRootViewController(animated: false)
        networkNavigationController.navigationController(
            networkNavigationController,
            didShow: listViewController,
            animated: false
        )

        #expect(session.runtime.network.model.selectedEntry == nil)
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
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

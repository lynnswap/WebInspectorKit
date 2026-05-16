#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
struct ParentContainerTests {
    @Test
    func sessionAndViewControllerUseDOMAndNetworkTabsByDefault() {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController()

        #expect(session.interface.tabs.map(\.id) == [WebInspectorTab.dom.id, WebInspectorTab.network.id])
        #expect(viewController.session.interface.tabs.map(\.id) == [WebInspectorTab.dom.id, WebInspectorTab.network.id])
    }

    @Test
    func viewControllerPreviewSessionInjectsMockDOMAndNetworkModels() throws {
        let session = WebInspectorViewControllerPreviewFixtures.makeSession()

        #expect(session.inspector.dom.currentPageRootNode?.nodeName == "#document")
        #expect(session.inspector.network.requests.count >= 2)
        #expect(session.interface.networkPanelModel(for: session.inspector).displayRequests.isEmpty == false)
    }

    @Test
    func displayProjectionKeepsCompactElementTabAndRegularCombinedDOM() {
        let tabs: [WebInspectorTab] = [.dom, .network]
        let projection = TabDisplayProjection()

        #expect(
            projection.displayItems(for: .compact, tabs: tabs).map(\.id)
                == [WebInspectorTab.dom.id, TabDisplayItem.domElementID, WebInspectorTab.network.id]
        )
        #expect(
            projection.displayItems(for: .regular, tabs: tabs).map(\.id)
                == [WebInspectorTab.dom.id, WebInspectorTab.network.id]
        )
    }

    @Test
    func topLevelContainerSwitchesBetweenCompactAndRegularHosts() throws {
        let viewController = WebInspectorViewController()
        viewController.loadViewIfNeeded()

        viewController.horizontalSizeClassOverrideForTesting = .compact
        #expect(viewController.activeHostViewControllerForTesting is CompactTabBarController)

        viewController.horizontalSizeClassOverrideForTesting = .regular
        #expect(viewController.activeHostViewControllerForTesting is RegularTabContentViewController)
    }

    @Test
    func compactHostDisplaysDOMElementAndNetworkTabs() {
        let session = WebInspectorSession()
        let host = CompactTabBarController(session: session)

        #expect(
            host.displayedTabIdentifiersForTesting
                == [WebInspectorTab.dom.id, TabDisplayItem.domElementID, WebInspectorTab.network.id]
        )
    }

    @Test
    func compactFactoryUsesDomainNavigationControllers() throws {
        let session = WebInspectorSession()

        let domViewController = TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? DOMCompactNavigationController)
        #expect(domNavigationController.viewControllers.first is DOMTreeViewController)

        let elementViewController = TabContentFactory.makeViewController(
            for: .domElement(parent: WebInspectorTab.dom.id),
            session: session,
            hostLayout: .compact
        )
        let elementNavigationController = try #require(elementViewController as? DOMCompactNavigationController)
        #expect(elementNavigationController.viewControllers.first is DOMElementViewController)

        let networkViewController = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let networkNavigationController = try #require(networkViewController as? NetworkCompactNavigationController)
        #expect(networkNavigationController.viewControllers.first is NetworkListViewController)
    }

    @Test
    func regularHostWrapsDomainSplitControllersBeforeInstallingInNavigationStack() throws {
        let session = WebInspectorSession()
        let host = RegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController is UISplitViewController == false)
        #expect(rootViewController.children.contains { $0 is DOMSplitViewController })
        #expect(rootViewController.navigationItem.centerItemGroups.isEmpty == false)
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WebInspector.DOM.PickButton" }
        )
    }

    @Test
    func regularNetworkRootExposesOnlyDetailModeNavigationItem() throws {
        let session = WebInspectorSession()
        session.interface.selectTab(.network)
        let host = RegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController.navigationItem.searchController == nil)
        #expect(rootViewController.navigationItem.additionalOverflowItems == nil)
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WebInspector.Network.DetailModeButton.Regular" }
        )
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains {
                    $0.accessibilityIdentifier == "WebInspector.Network.FilterButton"
                        || $0.accessibilityIdentifier == "WebInspector.DOM.PickButton"
                } == false
        )
    }

    @Test
    func cachedDOMTreeControllerIsSharedAcrossCompactAndRegularHosts() throws {
        let session = WebInspectorSession()
        let compactViewController = TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let compactNavigationController = try #require(compactViewController as? DOMCompactNavigationController)
        let compactTreeViewController = try #require(
            compactNavigationController.viewControllers.first as? DOMTreeViewController
        )

        let regularRoot = TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        regularRoot.loadViewIfNeeded()

        let splitViewController = try childViewController(
            ofType: DOMSplitViewController.self,
            in: regularRoot
        )
        let regularTreeViewController = try #require(
            splitRootViewController(
                ofType: DOMTreeViewController.self,
                in: splitViewController
            )
        )

        #expect(regularTreeViewController === compactTreeViewController)
    }

    @Test
    func networkPanelModelSelectionIsSharedAcrossParentHosts() async throws {
        let session = WebInspectorSession()
        let request = try #require(
            applyRequest(
                to: session.inspector.network,
                requestID: "1",
                url: "https://example.com/app.js"
            )
        )
        let model = session.interface.networkPanelModel(for: session.inspector)
        let compactNavigationController = try #require(
            TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? NetworkCompactNavigationController
        )
        let window = showInWindow(compactNavigationController)
        defer { window.isHidden = true }

        model.selectRequest(request)

        let didPushDetail = await waitUntil {
            compactNavigationController.viewControllers.last is NetworkDetailViewController
        }
        #expect(didPushDetail)

        let regularRoot = TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        regularRoot.loadViewIfNeeded()
        let splitViewController = try childViewController(
            ofType: NetworkSplitViewController.self,
            in: regularRoot
        )
        let detailViewController = try #require(
            splitRootViewController(
                ofType: NetworkDetailViewController.self,
                in: splitViewController
            )
        )

        let didRenderDetail = await waitUntil {
            detailViewController.collectionViewForTesting.isHidden == false
        }
        #expect(didRenderDetail)
    }

    private func childViewController<T: UIViewController>(
        ofType type: T.Type,
        in rootViewController: UIViewController
    ) throws -> T {
        try #require(rootViewController.children.first { $0 is T } as? T)
    }

    private func splitRootViewController<T: UIViewController>(
        ofType type: T.Type,
        in splitViewController: UISplitViewController
    ) -> T? {
        for column in splitColumns {
            guard let navigationController = splitViewController.viewController(for: column) as? UINavigationController,
                  let rootViewController = navigationController.viewControllers.first as? T else {
                continue
            }
            return rootViewController
        }
        return nil
    }

    private var splitColumns: [UISplitViewController.Column] {
        if #available(iOS 26.0, *) {
            [.primary, .supplementary, .secondary, .inspector]
        } else {
            [.primary, .supplementary, .secondary]
        }
    }

    private func applyRequest(
        to network: NetworkSession,
        requestID rawRequestID: String,
        url: String
    ) -> NetworkRequest? {
        let targetID = ProtocolTargetIdentifier("page")
        let requestID = NetworkRequestIdentifier(rawRequestID)
        let key = network.applyRequestWillBeSent(
            targetID: targetID,
            requestID: requestID,
            frameID: DOMFrameIdentifier("main"),
            loaderID: "loader",
            documentURL: "https://example.com",
            request: NetworkRequestPayload(
                url: url,
                method: "GET"
            ),
            resourceType: .script,
            timestamp: 1
        )
        network.applyResponseReceived(
            targetID: targetID,
            requestID: requestID,
            resourceType: .script,
            response: NetworkResponsePayload(
                url: url,
                status: 200,
                statusText: "OK",
                headers: ["content-type": "text/javascript"],
                mimeType: "text/javascript"
            ),
            timestamp: 2
        )
        network.applyLoadingFinished(
            targetID: targetID,
            requestID: requestID,
            timestamp: 3
        )
        return network.request(for: key)
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(
        maxTicks: Int = 256,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
#endif

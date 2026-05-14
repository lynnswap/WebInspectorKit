#if canImport(UIKit)
import Testing
import UIKit
@testable import V2_WebInspectorCore
@testable import V2_WebInspectorRuntime
@testable import V2_WebInspectorUI

@MainActor
struct V2_ParentContainerTests {
    @Test
    func sessionAndViewControllerUseDOMAndNetworkTabsByDefault() {
        let session = V2_WISession()
        let viewController = V2_WIViewController()

        #expect(session.interface.tabs.map(\.id) == [V2_WITab.dom.id, V2_WITab.network.id])
        #expect(viewController.session.interface.tabs.map(\.id) == [V2_WITab.dom.id, V2_WITab.network.id])
    }

    @Test
    func viewControllerPreviewSessionInjectsMockDOMAndNetworkModels() throws {
        let session = V2_WIViewControllerPreviewFixtures.makeSession()

        #expect(session.inspector.dom.currentPageRootNode?.nodeName == "#document")
        #expect(session.inspector.network.requests.count >= 2)
        #expect(session.interface.networkPanelModel(for: session.inspector).displayRequests.isEmpty == false)
    }

    @Test
    func displayProjectionKeepsCompactElementTabAndRegularCombinedDOM() {
        let tabs: [V2_WITab] = [.dom, .network]
        let projection = V2_TabDisplayProjection()

        #expect(
            projection.displayItems(for: .compact, tabs: tabs).map(\.id)
                == [V2_WITab.dom.id, V2_TabDisplayItem.domElementID, V2_WITab.network.id]
        )
        #expect(
            projection.displayItems(for: .regular, tabs: tabs).map(\.id)
                == [V2_WITab.dom.id, V2_WITab.network.id]
        )
    }

    @Test
    func topLevelContainerSwitchesBetweenCompactAndRegularHosts() throws {
        let viewController = V2_WIViewController()
        viewController.loadViewIfNeeded()

        viewController.horizontalSizeClassOverrideForTesting = .compact
        #expect(viewController.activeHostViewControllerForTesting is V2_CompactTabBarController)

        viewController.horizontalSizeClassOverrideForTesting = .regular
        #expect(viewController.activeHostViewControllerForTesting is V2_RegularTabContentViewController)
    }

    @Test
    func compactHostDisplaysDOMElementAndNetworkTabs() {
        let session = V2_WISession()
        let host = V2_CompactTabBarController(session: session)

        #expect(
            host.displayedTabIdentifiersForTesting
                == [V2_WITab.dom.id, V2_TabDisplayItem.domElementID, V2_WITab.network.id]
        )
    }

    @Test
    func compactFactoryUsesV2DomainNavigationControllers() throws {
        let session = V2_WISession()

        let domViewController = V2_TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? V2_DOMCompactNavigationController)
        #expect(domNavigationController.viewControllers.first is V2_DOMTreeViewController)

        let elementViewController = V2_TabContentFactory.makeViewController(
            for: .domElement(parent: V2_WITab.dom.id),
            session: session,
            hostLayout: .compact
        )
        let elementNavigationController = try #require(elementViewController as? V2_DOMCompactNavigationController)
        #expect(elementNavigationController.viewControllers.first is V2_DOMElementViewController)

        let networkViewController = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let networkNavigationController = try #require(networkViewController as? V2_NetworkCompactNavigationController)
        #expect(networkNavigationController.viewControllers.first is V2_NetworkListViewController)
    }

    @Test
    func regularHostWrapsDomainSplitControllersBeforeInstallingInNavigationStack() throws {
        let session = V2_WISession()
        let host = V2_RegularTabContentViewController(session: session)

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController is UISplitViewController == false)
        #expect(rootViewController.children.contains { $0 is V2_DOMSplitViewController })
        #expect(rootViewController.navigationItem.centerItemGroups.isEmpty == false)
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WebInspector.DOM.PickButton.V2" }
        )
    }

    @Test
    func regularNetworkRootExposesOnlyDetailModeNavigationItem() throws {
        let session = V2_WISession()
        session.interface.selectTab(.network)
        let host = V2_RegularTabContentViewController(session: session)

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
                    $0.accessibilityIdentifier == "WI.Network.FilterButton"
                        || $0.accessibilityIdentifier == "WebInspector.DOM.PickButton.V2"
                } == false
        )
    }

    @Test
    func cachedDOMTreeControllerIsSharedAcrossCompactAndRegularHosts() throws {
        let session = V2_WISession()
        let compactViewController = V2_TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let compactNavigationController = try #require(compactViewController as? V2_DOMCompactNavigationController)
        let compactTreeViewController = try #require(
            compactNavigationController.viewControllers.first as? V2_DOMTreeViewController
        )

        let regularRoot = V2_TabContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .regular
        )
        regularRoot.loadViewIfNeeded()

        let splitViewController = try childViewController(
            ofType: V2_DOMSplitViewController.self,
            in: regularRoot
        )
        let regularTreeViewController = try #require(
            splitRootViewController(
                ofType: V2_DOMTreeViewController.self,
                in: splitViewController
            )
        )

        #expect(regularTreeViewController === compactTreeViewController)
    }

    @Test
    func networkPanelModelSelectionIsSharedAcrossParentHosts() async throws {
        let session = V2_WISession()
        let request = try #require(
            applyRequest(
                to: session.inspector.network,
                requestID: "1",
                url: "https://example.com/app.js"
            )
        )
        let model = session.interface.networkPanelModel(for: session.inspector)
        let compactNavigationController = try #require(
            V2_TabContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? V2_NetworkCompactNavigationController
        )
        let window = showInWindow(compactNavigationController)
        defer { window.isHidden = true }

        model.selectRequest(request)

        let didPushDetail = await waitUntil {
            compactNavigationController.viewControllers.last is V2_NetworkDetailViewController
        }
        #expect(didPushDetail)

        let regularRoot = V2_TabContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        regularRoot.loadViewIfNeeded()
        let splitViewController = try childViewController(
            ofType: V2_NetworkSplitViewController.self,
            in: regularRoot
        )
        let detailViewController = try #require(
            splitRootViewController(
                ofType: V2_NetworkDetailViewController.self,
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

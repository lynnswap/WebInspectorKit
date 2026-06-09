#if canImport(UIKit)
import Testing
import WebInspectorTransport
import UIKit
import WebKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
struct ParentContainerTests {
    private enum TestAttachError: Error, Equatable {
        case failed
    }

    @Test
    func sessionAndViewControllerUseDOMAndNetworkTabsByDefault() {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController()

        #expect(session.interface.tabs.map(\.id) == [WebInspectorTab.dom.id, WebInspectorTab.network.id])
        #expect(viewController.session.interface.tabs.map(\.id) == [WebInspectorTab.dom.id, WebInspectorTab.network.id])
        if #available(iOS 26.0, *) {
            #expect(viewController.drawsBackground)
        }
    }

    @Test
    func viewControllerBackgroundDrawingDefaultsToSystemBackground() {
        let viewController = WebInspectorViewController()

        viewController.loadViewIfNeeded()

        if #available(iOS 26.0, *) {
            #expect(viewController.drawsBackground)
        }
        #expect(viewController.view.backgroundColor == .systemBackground)
    }

    @Test
    func pageAppearanceStyleUsesWebKitLightnessThreshold() {
        let traits = UITraitCollection(userInterfaceStyle: .light)

        #expect(WebInspectorPageAppearance.interfaceStyle(for: .white, in: traits) == .light)
        #expect(WebInspectorPageAppearance.interfaceStyle(for: .black, in: traits) == .dark)
        #expect(
            WebInspectorPageAppearance.interfaceStyle(
                for: UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                in: traits
            ) == .dark
        )
        #expect(
            WebInspectorPageAppearance.interfaceStyle(
                for: UIColor(red: 0.51, green: 0.51, blue: 0.51, alpha: 1),
                in: traits
            ) == .light
        )
        #expect(
            WebInspectorPageAppearance.interfaceStyle(
                for: UIColor(red: 0, green: 0, blue: 0, alpha: 0.01),
                in: traits
            ) == .unspecified
        )
    }

    @Test
    func pageAppearanceStyleResolvesDynamicColorsWithWebViewTraits() {
        let dynamicColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }

        #expect(
            WebInspectorPageAppearance.interfaceStyle(
                for: dynamicColor,
                in: UITraitCollection(userInterfaceStyle: .light)
            ) == .light
        )
        #expect(
            WebInspectorPageAppearance.interfaceStyle(
                for: dynamicColor,
                in: UITraitCollection(userInterfaceStyle: .dark)
            ) == .dark
        )
    }

    @Test
    func sessionUpdatesPreferredInterfaceStyleFromUnderPageBackgroundColor() async {
        let session = WebInspectorSession()
        let webView = WKWebView(frame: .zero)

        session.startPageAppearanceObservationForTesting(webView: webView)
        webView.underPageBackgroundColor = .black

        let didApplyDarkStyle = await waitUntil {
            session.interface.preferredInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)

        webView.underPageBackgroundColor = .white
        let didApplyLightStyle = await waitUntil {
            session.interface.preferredInterfaceStyle == .light
        }
        #expect(didApplyLightStyle)
    }

    @Test
    func sessionDetachClearsPageAppearanceObservation() async {
        let session = WebInspectorSession()
        let webView = WKWebView(frame: .zero)

        session.startPageAppearanceObservationForTesting(webView: webView)
        webView.underPageBackgroundColor = .black
        let didApplyDarkStyle = await waitUntil {
            session.interface.preferredInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)

        await session.detach()

        #expect(session.interface.preferredInterfaceStyle == .unspecified)
        webView.underPageBackgroundColor = .white
        await Task.yield()
        #expect(session.interface.preferredInterfaceStyle == .unspecified)
    }

    @Test
    func attachFailureClearsPreviousPageAppearanceObservation() async {
        let session = WebInspectorSession(
            inspector: InspectorSession(),
            attachAction: { _, _ in throw TestAttachError.failed }
        )
        let observedWebView = WKWebView(frame: .zero)
        session.startPageAppearanceObservationForTesting(webView: observedWebView)
        observedWebView.underPageBackgroundColor = .black
        let didApplyDarkStyle = await waitUntil {
            session.interface.preferredInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)

        await #expect(throws: TestAttachError.failed) {
            try await session.attach(to: WKWebView(frame: .zero))
        }

        #expect(session.interface.preferredInterfaceStyle == .unspecified)
        observedWebView.underPageBackgroundColor = .white
        await Task.yield()
        #expect(session.interface.preferredInterfaceStyle == .unspecified)
    }

    @Test
    func viewControllerIgnoresSessionPreferredInterfaceStyleByDefault() async {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.followsInspectedPageAppearance == false)

        session.interface.setPreferredInterfaceStyle(.dark)
        await Task.yield()
        #expect(viewController.overrideUserInterfaceStyle == .unspecified)

        session.interface.setPreferredInterfaceStyle(.light)
        await Task.yield()
        #expect(viewController.overrideUserInterfaceStyle == .unspecified)
    }

    @Test
    func viewControllerPreservesManualInterfaceStyleOverrideWhenPageFollowingIsDisabled() async {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.overrideUserInterfaceStyle = .dark
        session.interface.setPreferredInterfaceStyle(.light)
        await Task.yield()
        #expect(viewController.overrideUserInterfaceStyle == .dark)

        session.interface.setPreferredInterfaceStyle(.unspecified)
        await Task.yield()
        #expect(viewController.overrideUserInterfaceStyle == .dark)
    }

    @Test
    func viewControllerAppliesCurrentSessionPreferredInterfaceStyleWhenOptingIn() async {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        session.interface.setPreferredInterfaceStyle(.dark)
        viewController.followsInspectedPageAppearance = true

        let didApplyDarkStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .dark
                && viewController.traitCollection.userInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)
    }

    @Test
    func viewControllerFollowsSessionPreferredInterfaceStyleWhileOptedIn() async throws {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController(session: session)
        viewController.followsInspectedPageAppearance = true
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        session.interface.setPreferredInterfaceStyle(.dark)
        let didApplyDarkStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .dark
                && viewController.traitCollection.userInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)

        viewController.horizontalSizeClassOverrideForTesting = .compact
        let compactHost = try #require(viewController.activeHostViewControllerForTesting as? CompactTabBarController)
        compactHost.loadViewIfNeeded()
        #expect(compactHost.overrideUserInterfaceStyle == .unspecified)
        let didInheritDarkStyle = await waitUntil {
            compactHost.traitCollection.userInterfaceStyle == .dark
        }
        #expect(didInheritDarkStyle)

        session.interface.setPreferredInterfaceStyle(.light)
        let didApplyLightStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .light
                && viewController.traitCollection.userInterfaceStyle == .light
        }
        #expect(didApplyLightStyle)
    }

    @Test
    func viewControllerClearsAndIgnoresSessionPreferredInterfaceStyleWhenOptingOut() async {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController(session: session)
        viewController.followsInspectedPageAppearance = true
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        session.interface.setPreferredInterfaceStyle(.dark)
        let didApplyDarkStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)

        viewController.followsInspectedPageAppearance = false
        let didClearStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .unspecified
        }
        #expect(didClearStyle)

        session.interface.setPreferredInterfaceStyle(.light)
        await Task.yield()
        #expect(viewController.overrideUserInterfaceStyle == .unspecified)
    }

    @Test
    func viewControllerClearsPreferredInterfaceStyleWhenSessionStyleBecomesUnspecified() async {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController(session: session)
        viewController.followsInspectedPageAppearance = true
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        session.interface.setPreferredInterfaceStyle(.dark)
        let didApplyDarkStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .dark
        }
        #expect(didApplyDarkStyle)

        session.interface.setPreferredInterfaceStyle(.unspecified)
        let didApplyUnspecifiedStyle = await waitUntil {
            viewController.overrideUserInterfaceStyle == .unspecified
        }
        #expect(didApplyUnspecifiedStyle)
    }

    @Test
    func viewControllerCanDisableBackgroundDrawingAfterInitialization() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let viewController = WebInspectorViewController(session: WebInspectorSession())
        viewController.drawsBackground = false
        viewController.loadViewIfNeeded()

        #expect(viewController.drawsBackground == false)
        #expect(viewController.view.backgroundColor == .clear)
    }

    @Test
    func tabsInitializerKeepsBackgroundDrawingEnabledByDefault() {
        let viewController = WebInspectorViewController(tabs: [.network])

        viewController.loadViewIfNeeded()

        if #available(iOS 26.0, *) {
            #expect(viewController.drawsBackground)
        }
        #expect(viewController.session.interface.tabs.map(\.id) == [WebInspectorTab.network.id])
        #expect(viewController.view.backgroundColor == .systemBackground)
    }

    @Test
    func viewControllerPreviewSessionInjectsMockDOMAndNetworkModels() throws {
        let session = WebInspectorViewControllerPreviewFixtures.makeSession()

        #expect(session.attachment.dom.currentPageRootNode?.nodeName == "#document")
        #expect(session.attachment.network.requests.count >= 2)
        #expect(session.interface.networkPanelModel(for: session.attachment).displayRequests.isEmpty == false)
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
    func topLevelContainerPropagatesBackgroundDrawingTraitToHosts() throws {
        guard #available(iOS 26.0, *) else {
            return
        }

        let viewController = WebInspectorViewController()
        viewController.drawsBackground = false
        viewController.loadViewIfNeeded()

        viewController.horizontalSizeClassOverrideForTesting = .compact
        let compactHost = try #require(viewController.activeHostViewControllerForTesting as? CompactTabBarController)
        compactHost.loadViewIfNeeded()
        #expect(compactHost.view.backgroundColor == .clear)

        viewController.drawsBackground = true
        viewController.horizontalSizeClassOverrideForTesting = .regular
        let regularHost = try #require(viewController.activeHostViewControllerForTesting as? RegularTabContentViewController)
        regularHost.loadViewIfNeeded()
        #expect(regularHost.view.backgroundColor == .systemBackground)
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
                to: session.attachment.network,
                requestID: "1",
                url: "https://example.com/app.js"
            )
        )
        let model = session.interface.networkPanelModel(for: session.attachment)
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
        detailViewController.loadViewIfNeeded()

        let didRenderDetail = await waitUntil {
            detailViewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /app.js")
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

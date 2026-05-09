#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import Monocly
@testable import WebInspectorEngine
@_spi(Monocly) import WebInspectorRuntime
@testable import WebInspectorRuntime
@_spi(Monocly) import WebInspectorTransport
@testable import WebInspectorUI

final class BrowserNavigationChromeTests: XCTestCase {
    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    private var retainedWindows: [UIWindow] = []

    override func tearDown() {
        let cleanupExpectation = XCTestExpectation(description: "reset window context store")
        Task { @MainActor in
            MonoclyWindowContextStore.shared.resetForTesting()
            BrowserInspectorCoordinator.clearInspectorWindowPresentation()
            cleanupExpectation.fulfill()
        }
        let waitResult = XCTWaiter().wait(for: [cleanupExpectation], timeout: 2)
        if waitResult != .completed {
            XCTFail("Timed out while resetting the window context store.")
        }
        super.tearDown()
    }

    @MainActor
    func testAuthenticationChallengeUsesDefaultHandling() async {
        let store = BrowserStore(
            url: URL(string: "https://example.com")!,
            automaticallyLoadsInitialRequest: false
        )
        let protectionSpace = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )

        let response: (URLSession.AuthChallengeDisposition, URLCredential?) = await store.webView(
            store.webView,
            respondTo: challenge
        )
        let disposition = response.0
        let credential = response.1

        XCTAssertEqual(disposition, URLSession.AuthChallengeDisposition.performDefaultHandling)
        XCTAssertNil(credential)
    }

    @MainActor
    func testInitialCurrentURLSurvivesEmptyWebViewURL() {
        let initialURL = URL(string: "https://example.com/initial")!
        let store = BrowserStore(url: initialURL, automaticallyLoadsInitialRequest: false)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(store.webView.url)
        XCTAssertEqual(store.currentURL, initialURL)
    }

    @MainActor
    func testNavigationFailureClearsCurrentURLWhenWebViewURLIsNil() {
        let staleURL = URL(string: "https://example.com/stale")!
        let store = BrowserStore(url: staleURL, automaticallyLoadsInitialRequest: false)

        store.currentURL = staleURL
        store.webView(
            store.webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost
            )
        )

        XCTAssertNil(store.webView.url)
        XCTAssertNil(store.currentURL)
        XCTAssertNotNil(store.lastNavigationErrorDescription)
    }

    private struct HostedRootViewControllerFixture {
        let window: UIWindow
        let rootViewController: BrowserRootViewController
        let pageViewController: BrowserPageViewController
    }

    @MainActor
    func testCompactSizeClassUsesBottomToolbar() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertEqual(pageViewController.chromePlacementForTesting, "compactToolbar")
        XCTAssertFalse(rootViewController.isToolbarHidden)
        XCTAssertEqual(pageViewController.navigationItem.leadingItemGroups.count, 0)
        XCTAssertEqual(pageViewController.navigationItem.trailingItemGroups.count, 0)

        let toolbarItems = try XCTUnwrap(pageViewController.toolbarItems)
        XCTAssertTrue(toolbarItems.contains { $0 === pageViewController.backButtonItemForTesting })
        XCTAssertTrue(toolbarItems.contains { $0 === pageViewController.forwardButtonItemForTesting })
        XCTAssertTrue(toolbarItems.contains { $0 === pageViewController.inspectorButtonItemForTesting })
        XCTAssertNil(pageViewController.backButtonItemForTesting.customView)
        XCTAssertNil(pageViewController.forwardButtonItemForTesting.customView)
        XCTAssertNotNil(pageViewController.backButtonItemForTesting.primaryAction)
        XCTAssertNotNil(pageViewController.forwardButtonItemForTesting.primaryAction)
        XCTAssertNil(pageViewController.backButtonItemForTesting.menu)
        XCTAssertNil(pageViewController.forwardButtonItemForTesting.menu)
        XCTAssertEqual(pageViewController.backButtonItemForTesting.accessibilityIdentifier, "Monocly.navigation.back.compact")
        XCTAssertEqual(pageViewController.forwardButtonItemForTesting.accessibilityIdentifier, "Monocly.navigation.forward.compact")
        XCTAssertEqual(pageViewController.inspectorButtonItemForTesting.accessibilityIdentifier, "Monocly.openInspectorButton.compact")
    }

    @MainActor
    func testViewportChromeTopOverlapRequiresHostTopEdgeIntersection() {
        let hostFrame = CGRect(x: 40, y: 120, width: 320, height: 480)
        let chromeBelowHost = CGRect(x: 40, y: 620, width: 320, height: 44)
        let chromeCoveringTopEdge = CGRect(x: 40, y: 76, width: 320, height: 88)

        XCTAssertEqual(
            BrowserViewportChromeGeometry.topEdgeOverlapHeight(
                hostFrame: hostFrame,
                chromeFrame: chromeBelowHost
            ),
            0
        )
        XCTAssertEqual(
            BrowserViewportChromeGeometry.topEdgeOverlapHeight(
                hostFrame: hostFrame,
                chromeFrame: chromeCoveringTopEdge
            ),
            44
        )
    }

    @MainActor
    func testViewportChromeBottomOverlapRequiresFrameIntersection() {
        let hostFrame = CGRect(x: 40, y: 120, width: 320, height: 480)
        let chromeInDifferentColumn = CGRect(x: 420, y: 560, width: 320, height: 88)
        let chromeCoveringBottomEdge = CGRect(x: 40, y: 560, width: 320, height: 88)

        XCTAssertEqual(
            BrowserViewportChromeGeometry.bottomEdgeOverlapHeight(
                hostFrame: hostFrame,
                chromeFrame: chromeInDifferentColumn
            ),
            0
        )
        XCTAssertEqual(
            BrowserViewportChromeGeometry.bottomEdgeOverlapHeight(
                hostFrame: hostFrame,
                chromeFrame: chromeCoveringBottomEdge
            ),
            40
        )
    }

    @MainActor
    func testRegularSizeClassUsesNavigationBarItems() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertEqual(pageViewController.chromePlacementForTesting, "regularNavigationBar")
        XCTAssertTrue(rootViewController.isToolbarHidden)
        XCTAssertTrue(pageViewController.toolbarItems?.isEmpty ?? true)
        XCTAssertEqual(pageViewController.navigationItem.leadingItemGroups.count, 1)
        XCTAssertEqual(pageViewController.navigationItem.trailingItemGroups.count, 1)

        let leadingItems = pageViewController.navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
        let trailingItems = pageViewController.navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
        XCTAssertTrue(leadingItems.contains { $0 === pageViewController.backButtonItemForTesting })
        XCTAssertTrue(leadingItems.contains { $0 === pageViewController.forwardButtonItemForTesting })
        XCTAssertTrue(trailingItems.contains { $0 === pageViewController.inspectorButtonItemForTesting })
        XCTAssertNil(pageViewController.backButtonItemForTesting.customView)
        XCTAssertNil(pageViewController.forwardButtonItemForTesting.customView)
        XCTAssertNotNil(pageViewController.backButtonItemForTesting.primaryAction)
        XCTAssertNotNil(pageViewController.forwardButtonItemForTesting.primaryAction)
        XCTAssertEqual(pageViewController.backButtonItemForTesting.accessibilityIdentifier, "Monocly.navigation.back.regular")
        XCTAssertEqual(pageViewController.forwardButtonItemForTesting.accessibilityIdentifier, "Monocly.navigation.forward.regular")
        XCTAssertEqual(pageViewController.inspectorButtonItemForTesting.accessibilityIdentifier, "Monocly.openInspectorButton.regular")
        XCTAssertTrue(pageViewController.inspectorHasPrimaryActionForTesting)
        XCTAssertEqual(
            pageViewController.inspectorMenuActionTitlesForTesting,
            ["Open as Sheet", "Open in New Window"]
        )
    }

    @MainActor
    func testChromePlacementTransitionsBetweenCompactAndRegular() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)
        XCTAssertEqual(pageViewController.chromePlacementForTesting, "compactToolbar")
        XCTAssertEqual(pageViewController.navigationItem.title, "about:blank")
        XCTAssertFalse(rootViewController.isToolbarHidden)
        XCTAssertFalse(pageViewController.backButtonItemForTesting.isEnabled)
        XCTAssertFalse(pageViewController.forwardButtonItemForTesting.isEnabled)

        applyHorizontalSizeClass(.regular, to: rootViewController)
        XCTAssertEqual(pageViewController.chromePlacementForTesting, "regularNavigationBar")
        XCTAssertTrue(rootViewController.isToolbarHidden)
        XCTAssertEqual(pageViewController.navigationItem.title, "about:blank")
        XCTAssertFalse(pageViewController.backButtonItemForTesting.isEnabled)
        XCTAssertFalse(pageViewController.forwardButtonItemForTesting.isEnabled)

        applyHorizontalSizeClass(.compact, to: rootViewController)
        XCTAssertEqual(pageViewController.chromePlacementForTesting, "compactToolbar")
        XCTAssertFalse(rootViewController.isToolbarHidden)
        XCTAssertEqual(pageViewController.navigationItem.title, "about:blank")
        XCTAssertEqual(pageViewController.navigationItem.leadingItemGroups.count, 0)
        XCTAssertEqual(pageViewController.navigationItem.trailingItemGroups.count, 0)
        XCTAssertFalse(pageViewController.backButtonItemForTesting.isEnabled)
        XCTAssertFalse(pageViewController.forwardButtonItemForTesting.isEnabled)
    }

    @MainActor
    func testCompactToolbarContributesAdditionalBottomSafeArea() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)
        drainMainQueue()

        let adjustedBottomInset = rootViewController.store.webView.scrollView.adjustedContentInset.bottom
        let pageSafeAreaBottom = pageViewController.view.safeAreaInsets.bottom
        let windowSafeAreaBottom = rootViewController.view.window?.safeAreaInsets.bottom ?? 0

        XCTAssertEqual(adjustedBottomInset, pageSafeAreaBottom, accuracy: 0.5)
        XCTAssertGreaterThan(pageViewController.view.safeAreaInsets.bottom, windowSafeAreaBottom)
        XCTAssertGreaterThan(adjustedBottomInset, windowSafeAreaBottom)
    }

    @MainActor
    func testRegularNavigationBarContributesFullTopViewportInset() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)
        drainMainQueue()

        let adjustedTopInset = rootViewController.store.webView.scrollView.adjustedContentInset.top
        let pageSafeAreaTop = pageViewController.view.safeAreaInsets.top
        let windowSafeAreaTop = fixture.window.safeAreaInsets.top

        XCTAssertEqual(adjustedTopInset, pageSafeAreaTop, accuracy: 0.5)
        XCTAssertGreaterThan(adjustedTopInset, windowSafeAreaTop)
    }

    @MainActor
    func testCompactInspectorShowsElementTab() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)
        let inspectorContainer = try presentCompactInspector(from: pageViewController, rootViewController: rootViewController)
        let compactHost = try XCTUnwrap(inspectorContainer.activeHostViewControllerForTesting as? WICompactTabBarController)

        XCTAssertEqual(
            compactHost.displayedTabIdentifiersForTesting,
            ["wi_dom", "wi_dom.element", "wi_network"]
        )

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testCompactInspectorSelectionStaysLocalToPresentedSession() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)
        let firstInspector = try presentCompactInspector(from: pageViewController, rootViewController: rootViewController)
        let firstHost = try XCTUnwrap(firstInspector.activeHostViewControllerForTesting as? WICompactTabBarController)
        _ = try XCTUnwrap(firstHost.currentUITabsForTesting.first(where: { $0.identifier == "wi_dom.element" }))
        firstInspector.session.interface.selectItem(withID: "wi_dom.element")
        drainMainQueue()
        XCTAssertEqual(firstInspector.session.interface.selectedItemID, "wi_dom.element")
        XCTAssertEqual(firstInspector.session.interface.selectedTab?.id, "wi_dom")

        dismissPresentedInspector(from: rootViewController)

        let secondInspector = try presentCompactInspector(from: pageViewController, rootViewController: rootViewController)
        let secondHost = try XCTUnwrap(secondInspector.activeHostViewControllerForTesting as? WICompactTabBarController)

        XCTAssertEqual(secondHost.selectedTab?.identifier, "wi_dom")

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testRegularInspectorPrimaryActionPresentsSheetAndDisablesButtonWhileOpen() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)
        XCTAssertTrue(pageViewController.inspectorButtonItemForTesting.isEnabled)

        XCTAssertTrue(pageViewController.triggerInspectorPrimaryActionForTesting())
        drainMainQueue()

        XCTAssertTrue(rootViewController.presentedViewController is WIViewController)
        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WIViewController)
        let sheet = try XCTUnwrap(inspectorContainer.sheetPresentationController)
        XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
        XCTAssertEqual(sheet.largestUndimmedDetentIdentifier, .medium)
        XCTAssertFalse(pageViewController.inspectorButtonItemForTesting.isEnabled)

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testRegularInspectorSheetInstallsDismissDelegateOnPresentationController() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(pageViewController.triggerInspectorPrimaryActionForTesting())
        drainMainQueue()

        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WIViewController)
        XCTAssertNotNil(inspectorContainer.presentationController?.delegate)

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testInspectorSheetKeepsRuntimeAttachedWhenPresenterDisappearsDuringAdaptivePresentation() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "inspector-adaptive-sheet", title: "Inspector Adaptive Sheet")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorRuntime = rootViewController.inspectorRuntime

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)
        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        _ = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        var simulatedDisappearance = false
        defer {
            if simulatedDisappearance {
                rootViewController.beginAppearanceTransition(true, animated: false)
                rootViewController.endAppearanceTransition()
                drainMainQueue()
            }
            dismissPresentedInspector(from: rootViewController)
        }

        XCTAssertTrue(
            waitForCondition(description: "runtime attached before adaptive disappearance") {
                inspectorRuntime.dom.hasPageWebViewForDiagnostics
                    && inspectorRuntime.network.model.session.mode == .active
            }
        )

        rootViewController.beginAppearanceTransition(false, animated: false)
        rootViewController.endAppearanceTransition()
        simulatedDisappearance = true
        drainMainQueue()

        XCTAssertTrue(
            waitForCondition(description: "sheet presentation keeps root-owned runtime attached") {
                inspectorRuntime.dom.hasPageWebViewForDiagnostics
                    && inspectorRuntime.network.model.session.mode == .active
            },
            "Presenter disappearance during adaptive sheet presentation detached the shared inspector runtime."
        )
    }

    @MainActor
    func testInspectorSheetHostingControllerUsesClearBackground() {
        let browserStore = BrowserStore(
            url: URL(string: "about:blank")!,
            automaticallyLoadsInitialRequest: false
        )
        let controller = BrowserInspectorSheetHostingController(
            browserStore: browserStore,
            inspectorRuntime: WIRuntimeSession(),
            launchConfiguration: BrowserLaunchConfiguration(
                initialURL: URL(string: "about:blank")!,
                shouldShowDiagnostics: true,
                uiTestScenario: .domOpenInspectorAfterInitialLoad
            ),
            tabs: [.dom]
        )

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.view.backgroundColor, .clear)
    }

    @MainActor
    func testBrowserControllersUseClearBackgroundWithoutSystemFallback() throws {
        let fixture = try makeHostedRootViewController()

        XCTAssertEqual(fixture.rootViewController.view.backgroundColor, .clear)
        XCTAssertEqual(
            fixture.pageViewController.view.backgroundColor,
            fixture.rootViewController.store.underPageBackgroundColor
        )

        let inspectorWindowController = BrowserInspectorWindowHostingController()
        inspectorWindowController.loadViewIfNeeded()

        XCTAssertEqual(inspectorWindowController.view.backgroundColor, .clear)
    }

    @MainActor
    func testInspectorWindowHostingRefreshesWhenTabsChange() throws {
        let browserStore = BrowserStore(
            url: URL(string: "about:blank")!,
            automaticallyLoadsInitialRequest: false
        )
        let inspectorRuntime = WIRuntimeSession()
        BrowserInspectorCoordinator.setInspectorWindowContextForTesting(
            BrowserInspectorWindowContext(
                browserStore: browserStore,
                inspectorRuntime: inspectorRuntime,
                tabs: [.dom]
            )
        )

        let controller = BrowserInspectorWindowHostingController()
        controller.loadViewIfNeeded()

        let firstInspector = try XCTUnwrap(controller.children.compactMap { $0 as? WIViewController }.first)
        XCTAssertEqual(firstInspector.session.interface.tabs.map(\.id), [WITab.dom.id])

        BrowserInspectorCoordinator.setInspectorWindowContextForTesting(
            BrowserInspectorWindowContext(
                browserStore: browserStore,
                inspectorRuntime: inspectorRuntime,
                tabs: [.dom, .network]
            )
        )
        controller.updateInspectorContext()

        let updatedInspector = try XCTUnwrap(controller.children.compactMap { $0 as? WIViewController }.first)
        XCTAssertFalse(updatedInspector === firstInspector)
        XCTAssertEqual(updatedInspector.session.interface.tabs.map(\.id), [WITab.dom.id, WITab.network.id])
    }

    @MainActor
    func testPageViewControllerUsesUnderPageBackgroundColorWhenProvided() {
        let store = BrowserStore(
            url: URL(string: "about:blank")!,
            automaticallyLoadsInitialRequest: false
        )
        store.underPageBackgroundColor = .systemRed

        let controller = BrowserPageViewController(
            store: store,
            inspectorRuntime: WIRuntimeSession(),
            launchConfiguration: BrowserLaunchConfiguration(
                initialURL: URL(string: "about:blank")!
            )
        )

        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.view.backgroundColor, .systemRed)
    }

    @MainActor
    func testRegularInspectorWindowActionCreatesWindowAndPreventsReentry() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        var activationCount = 0
        var requestedActivity: NSUserActivity?
        var requestingScene: UIScene?

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)
        let hostWindowScene = try XCTUnwrap(fixture.window.windowScene)
        let alternateWindow = try makeWindow()
        retainedWindows.append(alternateWindow)
        alternateWindow.isHidden = false
        alternateWindow.makeKeyAndVisible()
        MonoclyWindowContextStore.shared.setCurrentSceneForTesting(
            try XCTUnwrap(alternateWindow.windowScene),
            window: alternateWindow
        )
        pageViewController.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, userActivity, scene, _ in
                    requestedActivity = userActivity
                    requestingScene = scene
                    activationCount += 1
                }
            )
        )

        XCTAssertTrue(pageViewController.triggerInspectorWindowActionForTesting())
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(requestedActivity?.activityType, BrowserInspectorCoordinator.inspectorWindowSceneActivityType)
        XCTAssertEqual(requestedActivity?.targetContentIdentifier, BrowserInspectorCoordinator.inspectorWindowSceneActivityType)
        XCTAssertTrue(requestingScene === hostWindowScene)

        XCTAssertTrue(pageViewController.hasInspectorWindowForTesting)
        XCTAssertFalse(pageViewController.inspectorButtonItemForTesting.isEnabled)

        XCTAssertFalse(pageViewController.triggerInspectorWindowActionForTesting())
        XCTAssertEqual(activationCount, 1)
        pageViewController.dismissInspectorWindowForTesting()
    }

    @MainActor
    func testRegularInspectorWindowActionUsesCurrentSceneContextWhenPresenterIsUnattached() throws {
        let fixture = try makeHostedRootViewController()
        let coordinator = BrowserInspectorCoordinator()
        let unattachedPresenter = UIViewController()
        var activationCount = 0
        var requestingScene: UIScene?

        coordinator.setSupportsMultipleScenesProviderForTesting { true }
        let windowScene = try XCTUnwrap(fixture.window.windowScene)
        MonoclyWindowContextStore.shared.setCurrentSceneForTesting(windowScene, window: fixture.window)
        addTeardownBlock {
            coordinator.dismissInspectorWindow()
        }

        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, scene, _ in
                    requestingScene = scene
                    activationCount += 1
                }
            )
        )

        XCTAssertTrue(
            coordinator.presentWindow(
                from: unattachedPresenter,
                browserStore: fixture.rootViewController.store,
                inspectorRuntime: fixture.rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
            )
        )
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(requestingScene === windowScene)
    }

    @MainActor
    func testInspectorWindowPresentationStateIgnoresAttachedScenesWithoutContext() {
        XCTAssertFalse(
            BrowserInspectorCoordinator.inspectorWindowPresentationStateForTesting(
                hasContext: false,
                isPendingPresentation: false,
                attachedSceneCount: 1
            )
        )
        XCTAssertTrue(
            BrowserInspectorCoordinator.inspectorWindowPresentationStateForTesting(
                hasContext: true,
                isPendingPresentation: false,
                attachedSceneCount: 1
            )
        )
    }

    @MainActor
    func testOpeningInspectorUsesRootOwnedNetworkRuntime() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "network-root-owned", title: "Network Root Owned")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorRuntime = rootViewController.inspectorRuntime

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))
        try seedNetworkStore(
            url: "https://example.com/root-owned-runtime",
            requestID: 700,
            into: inspectorRuntime.network.model.store
        )

        let inspector = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspector.session)

        let usesRootRuntime = waitForCondition(description: "inspector uses root-owned network runtime") {
            inspector.session.runtime === inspectorRuntime
                && inspectorRuntime.network.model.session.mode == .active
                && inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/root-owned-runtime" }
        }
        XCTAssertTrue(
            usesRootRuntime,
            "Opening the inspector did not use the root-owned network runtime and its existing store."
        )
    }

    @MainActor
    func testDismissingInspectorKeepsRootOwnedRuntimeAttachedAndNetworkStore() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "network-close", title: "Network Close")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorRuntime = rootViewController.inspectorRuntime

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        let inspector = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspector.session)
        try seedNetworkStore(
            url: "https://example.com/seed-close",
            requestID: 701,
            into: inspectorRuntime.network.model.store
        )

        let seeded = waitForCondition(description: "seed network entries before dismiss") {
            inspectorRuntime.network.model.session.mode == .active
                && inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-close" }
        }
        XCTAssertTrue(seeded, "The regular inspector did not expose the seeded network store entry before dismiss.")

        dismissPresentedInspector(from: rootViewController)

        let runtimeStayedAttached = waitForCondition(description: "dismiss inspector keeps root-owned runtime attached") {
            inspectorRuntime.dom.hasPageWebViewForDiagnostics
                && inspectorRuntime.network.model.session.mode == .active
                && inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-close" }
        }
        XCTAssertTrue(
            runtimeStayedAttached,
            "Dismissing the inspector detached or cleared the root-owned runtime."
        )
    }

    @MainActor
    func testReopeningInspectorReusesRootOwnedRuntimeNetworkEntries() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "network-reopen", title: "Network Reopen")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorRuntime = rootViewController.inspectorRuntime

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        let firstInspector = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: firstInspector.session)
        try seedNetworkStore(
            url: "https://example.com/seed-reopen",
            requestID: 702,
            into: inspectorRuntime.network.model.store
        )

        let firstSeed = waitForCondition(description: "seed network entry before reopen") {
            inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-reopen" }
        }
        XCTAssertTrue(firstSeed, "The first inspector presentation did not expose the seeded network entry.")

        dismissPresentedInspector(from: rootViewController)

        let retained = waitForCondition(description: "network store persists after dismiss") {
            inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-reopen" }
                && inspectorRuntime.network.model.session.mode == .active
        }
        XCTAssertTrue(retained, "The root-owned runtime did not preserve the network store after dismiss.")

        let secondInspector = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: secondInspector.session)
        let expectedFinishCount = rootViewController.store.didFinishNavigationCount + 1
        rootViewController.store.webView.reload()

        let rebound = waitForCondition(description: "network capture continues after reopen") {
            inspectorRuntime.dom.hasPageWebViewForDiagnostics
                && inspectorRuntime.network.model.session.mode == .active
                && rootViewController.store.didFinishNavigationCount >= expectedFinishCount
                && inspectorRuntime.network.model.store.entries.isEmpty == false
        }
        XCTAssertTrue(rebound, "Reopening the inspector did not produce a fresh network session after the page reloaded.")

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testSwitchingCompactInspectorTabsKeepsNetworkStoreWhileInspectorStaysPresented() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "network-tab-switch", title: "Network Tab Switch")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorRuntime = rootViewController.inspectorRuntime

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        let inspector = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspector.session)
        try seedNetworkStore(
            url: "https://example.com/seed-switch",
            requestID: 703,
            into: inspectorRuntime.network.model.store
        )

        let seeded = waitForCondition(description: "seed network entries before tab switch") {
            inspectorRuntime.network.model.session.mode == .active
                && inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-switch" }
        }
        XCTAssertTrue(seeded, "The inspector did not expose the seeded network entry before switching tabs.")

        let bootstrappedEntryCount = inspectorRuntime.network.model.store.entries.count
        selectInspectorTab("wi_dom", in: inspector.session)

        let switchedToDOM = waitForCondition(description: "switch to DOM without clearing network store") {
            inspectorRuntime.dom.hasPageWebViewForDiagnostics
                && inspectorRuntime.network.model.session.mode == .active
                && inspectorRuntime.network.model.store.entries.count >= bootstrappedEntryCount
                && inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-switch" }
        }
        XCTAssertTrue(switchedToDOM, "Switching away from the Network tab cleared the network store while the inspector stayed open.")

        selectInspectorTab("wi_network", in: inspector.session)

        let switchedBack = waitForCondition(description: "switch back to network without clearing network store") {
            inspectorRuntime.dom.hasPageWebViewForDiagnostics
                && inspectorRuntime.network.model.session.mode == .active
                && inspectorRuntime.network.model.store.entries.count >= bootstrappedEntryCount
                && inspectorRuntime.network.model.store.entries.contains { $0.url == "https://example.com/seed-switch" }
        }
        XCTAssertTrue(switchedBack, "Switching back to the Network tab did not preserve the existing network store entries.")

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testRegularInspectorUsesPlainButtonWhenMultipleScenesUnsupported() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertFalse(pageViewController.inspectorHasPrimaryActionForTesting)
        XCTAssertTrue(pageViewController.inspectorMenuActionTitlesForTesting.isEmpty)
    }

    @MainActor
    func testCompactInspectorUsesMenuWhenMultipleScenesSupported() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertTrue(pageViewController.inspectorHasPrimaryActionForTesting)
        XCTAssertEqual(
            pageViewController.inspectorMenuActionTitlesForTesting,
            ["Open as Sheet", "Open in New Window"]
        )
    }

    @MainActor
    func testCompactHistoryMenusShowDirectionSpecificEntriesNearestFirst() throws {
        let firstURL = try makeTemporaryHTMLURL(named: "first", title: "First Page")
        let secondURL = try makeTemporaryHTMLURL(named: "second", title: "Second Page")
        let thirdURL = try makeTemporaryHTMLURL(named: "third", title: "Third Page")

        let fixture = try makeHostedRootViewController(initialURL: firstURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let store = rootViewController.store

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 1, in: store))

        let secondFinishCount = store.didFinishNavigationCount + 1
        store.webView.load(URLRequest(url: secondURL))
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: secondFinishCount, in: store))

        let thirdFinishCount = store.didFinishNavigationCount + 1
        store.webView.load(URLRequest(url: thirdURL))
        XCTAssertTrue(waitForNavigation(to: thirdURL, minimumDidFinishCount: thirdFinishCount, in: store))

        pageViewController.view.layoutIfNeeded()

        XCTAssertEqual(
            pageViewController.backMenuActionTitlesForTesting,
            ["First Page", "Second Page"]
        )
        XCTAssertEqual(
            pageViewController.forwardMenuActionTitlesForTesting,
            []
        )
        XCTAssertEqual(
            pageViewController.backMenuActionSubtitlesForTesting.compactMap(\.self),
            [firstURL.absoluteString, secondURL.absoluteString]
        )
    }

    @MainActor
    func testRapidSuccessiveLoadsDoNotLeaveCancelledNavigationErrorState() throws {
        let firstURL = try makeTemporaryHTMLURL(named: "first-cancelled", title: "First Cancelled Page")
        let secondURL = try makeTemporaryHTMLURL(named: "second-final", title: "Second Final Page")

        let fixture = try makeHostedRootViewController()
        let store = fixture.rootViewController.store

        XCTAssertTrue(waitForNavigation(to: URL(string: "about:blank")!, minimumDidFinishCount: 1, in: store))

        let initialCommitCount = store.didCommitNavigationCount
        let initialFinishCount = store.didFinishNavigationCount

        store.load(url: firstURL)
        store.load(url: secondURL)

        let finalLoadCompleted = waitForCondition(description: "rapid successive load settles on final page") {
            store.currentURL == secondURL
                && store.didCommitNavigationCount > initialCommitCount
                && store.didFinishNavigationCount > initialFinishCount
                && store.isLoading == false
        }
        XCTAssertTrue(finalLoadCompleted, "The browser did not settle on the final navigation target after cancelling the earlier request.")
        XCTAssertEqual(store.currentURL, secondURL)
        XCTAssertNil(store.lastNavigationErrorDescription)
        XCTAssertGreaterThan(store.didCommitNavigationCount, initialCommitCount)
    }

    @MainActor
    func testForwardHistoryMenuAppearsAfterGoingBack() throws {
        let firstURL = try makeTemporaryHTMLURL(named: "first", title: "First Page")
        let secondURL = try makeTemporaryHTMLURL(named: "second", title: "Second Page")
        let thirdURL = try makeTemporaryHTMLURL(named: "third", title: "Third Page")

        let fixture = try makeHostedRootViewController(initialURL: firstURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let store = rootViewController.store

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 1, in: store))

        store.webView.load(URLRequest(url: secondURL))
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 2, in: store))

        store.webView.load(URLRequest(url: thirdURL))
        XCTAssertTrue(waitForNavigation(to: thirdURL, minimumDidFinishCount: 3, in: store))

        store.goBack()
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 4, in: store))

        pageViewController.view.layoutIfNeeded()

        XCTAssertEqual(pageViewController.forwardMenuActionTitlesForTesting, ["Third Page"])
        XCTAssertEqual(
            pageViewController.forwardMenuActionSubtitlesForTesting.compactMap(\.self),
            [thirdURL.absoluteString]
        )
    }

    @MainActor
    func testSelectingHistoryMenuEntryNavigatesDirectly() throws {
        let firstURL = try makeTemporaryHTMLURL(named: "first", title: "First Page")
        let secondURL = try makeTemporaryHTMLURL(named: "second", title: "Second Page")
        let thirdURL = try makeTemporaryHTMLURL(named: "third", title: "Third Page")

        let fixture = try makeHostedRootViewController(initialURL: firstURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let store = rootViewController.store

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 1, in: store))

        store.webView.load(URLRequest(url: secondURL))
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 2, in: store))

        store.webView.load(URLRequest(url: thirdURL))
        XCTAssertTrue(waitForNavigation(to: thirdURL, minimumDidFinishCount: 3, in: store))

        XCTAssertTrue(pageViewController.triggerBackHistorySelectionForTesting(index: 1))
        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 4, in: store))
        XCTAssertEqual(store.currentURL, firstURL)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)
        XCTAssertTrue(pageViewController.forwardButtonItemForTesting.menu != nil)
    }

    @MainActor
    func testReloadDoesNotRecreateHistoryMenusWhenHistoryIsUnchanged() throws {
        let firstURL = try makeTemporaryHTMLURL(named: "first", title: "First Page")
        let secondURL = try makeTemporaryHTMLURL(named: "second", title: "Second Page")

        let fixture = try makeHostedRootViewController(initialURL: firstURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let store = rootViewController.store

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 1, in: store))

        store.webView.load(URLRequest(url: secondURL))
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 2, in: store))

        let backMenuBeforeReload = try XCTUnwrap(pageViewController.backMenuForTesting)

        store.webView.reload()
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 3, in: store))

        let backMenuAfterReload = try XCTUnwrap(pageViewController.backMenuForTesting)
        XCTAssertTrue(backMenuBeforeReload === backMenuAfterReload)
    }

    @MainActor
    func testHistoryChangeRecreatesMenus() throws {
        let firstURL = try makeTemporaryHTMLURL(named: "first", title: "First Page")
        let secondURL = try makeTemporaryHTMLURL(named: "second", title: "Second Page")
        let thirdURL = try makeTemporaryHTMLURL(named: "third", title: "Third Page")

        let fixture = try makeHostedRootViewController(initialURL: firstURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let store = rootViewController.store

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 1, in: store))

        store.webView.load(URLRequest(url: secondURL))
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 2, in: store))

        let backMenuAfterSecondPage = try XCTUnwrap(pageViewController.backMenuForTesting)

        store.webView.load(URLRequest(url: thirdURL))
        XCTAssertTrue(waitForNavigation(to: thirdURL, minimumDidFinishCount: 3, in: store))

        let backMenuAfterThirdPage = try XCTUnwrap(pageViewController.backMenuForTesting)
        XCTAssertFalse(backMenuAfterSecondPage === backMenuAfterThirdPage)

        store.goBack()
        XCTAssertTrue(waitForNavigation(to: secondURL, minimumDidFinishCount: 4, in: store))

        let forwardMenuAfterSingleBack = try XCTUnwrap(pageViewController.forwardMenuForTesting)

        store.goBack()
        XCTAssertTrue(waitForNavigation(to: firstURL, minimumDidFinishCount: 5, in: store))

        let forwardMenuAfterDoubleBack = try XCTUnwrap(pageViewController.forwardMenuForTesting)
        XCTAssertFalse(forwardMenuAfterSingleBack === forwardMenuAfterDoubleBack)
    }
}

private extension BrowserNavigationChromeTests {
    @MainActor
    private func makeHostedRootViewController(
        initialURL: URL = URL(string: "about:blank")!
    ) throws -> HostedRootViewControllerFixture {
        let rootViewController = BrowserRootViewController(
            launchConfiguration: BrowserLaunchConfiguration(
                initialURL: initialURL
            )
        )
        let window = try makeWindow()
        retainedWindows.append(window)
        addTeardownBlock { [window] in
            if let rootViewController = window.rootViewController as? BrowserRootViewController {
                self.dismissPresentedInspector(from: rootViewController)
            } else {
                window.rootViewController?.dismiss(animated: false)
                self.drainMainQueue()
            }
            window.isHidden = true
            window.rootViewController = nil
            self.drainMainQueue()
            self.retainedWindows.removeAll { $0 === window }
        }
        window.rootViewController = rootViewController
        rootViewController.loadViewIfNeeded()
        window.isHidden = false
        window.makeKeyAndVisible()
        drainMainQueue()
        rootViewController.view.layoutIfNeeded()

        let pageViewController = try XCTUnwrap(rootViewController.pageViewControllerForTesting)
        pageViewController.loadViewIfNeeded()
        pageViewController.view.layoutIfNeeded()

        return HostedRootViewControllerFixture(
            window: window,
            rootViewController: rootViewController,
            pageViewController: pageViewController
        )
    }

    @MainActor
    func makeWindow() throws -> UIWindow {
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        return UIWindow(windowScene: windowScene)
    }

    @MainActor
    func applyHorizontalSizeClass(
        _ sizeClass: UIUserInterfaceSizeClass,
        to rootViewController: BrowserRootViewController
    ) {
        rootViewController.traitOverrides.horizontalSizeClass = sizeClass
        rootViewController.updateTraitsIfNeeded()
        rootViewController.view.layoutIfNeeded()
        rootViewController.pageViewControllerForTesting?.view.layoutIfNeeded()
    }

    @MainActor
    func presentCompactInspector(
        from pageViewController: BrowserPageViewController,
        rootViewController: BrowserRootViewController
    ) throws -> WIViewController {
        let buttonItem = pageViewController.inspectorButtonItemForTesting
        let action = try XCTUnwrap(buttonItem.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: buttonItem.target, from: buttonItem, for: nil))
        drainMainQueue()

        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WIViewController)
        inspectorContainer.horizontalSizeClassOverrideForTesting = .compact
        inspectorContainer.loadViewIfNeeded()
        inspectorContainer.view.layoutIfNeeded()
        return inspectorContainer
    }

    @MainActor
    func presentRegularInspector(
        from pageViewController: BrowserPageViewController,
        rootViewController: BrowserRootViewController
    ) throws -> WIViewController {
        XCTAssertTrue(pageViewController.triggerInspectorPrimaryActionForTesting())
        drainMainQueue()

        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WIViewController)
        inspectorContainer.loadViewIfNeeded()
        inspectorContainer.view.layoutIfNeeded()
        return inspectorContainer
    }

    @MainActor
    func selectCompactInspectorTab(
        _ identifier: String,
        in inspectorContainer: WIViewController
    ) throws {
        let compactHost = try XCTUnwrap(inspectorContainer.activeHostViewControllerForTesting as? WICompactTabBarController)
        _ = try XCTUnwrap(compactHost.currentUITabsForTesting.first(where: { $0.identifier == identifier }))
        inspectorContainer.session.interface.selectItem(withID: identifier)
        drainMainQueue()
    }

    @MainActor
    func selectInspectorTab(_ identifier: String, in session: WISession) {
        session.interface.selectTab(withID: identifier)
        drainMainQueue()
    }

    @MainActor
    func seedNetworkStore(
        url: String,
        requestID: Int,
        into store: NetworkStore
    ) throws {
        let payload: [String: Any] = [
            "kind": "requestWillBeSent",
            "requestId": requestID,
            "url": url,
            "method": "GET",
            "time": [
                "monotonicMs": 1_000.0,
                "wallMs": 1_700_000_000_000.0
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try JSONDecoder().decode(NetworkWire.PageHook.Event.self, from: data)
        store.apply(event, sessionID: "")
    }

    @MainActor
    func installSyntheticResourceTimings(
        _ entries: [[String: Any]],
        on webView: WKWebView
    ) throws {
        let expectation = XCTestExpectation(description: "install synthetic resource timings")
        var installed = false
        var capturedError: Error?

        Task { @MainActor in
            defer { expectation.fulfill() }
            do {
                let result = try await webView.callAsyncJavaScriptCompat(
                    """
                    return (function(entries) {
                        const prototype = Object.getPrototypeOf(performance) || performance;
                        const original = performance.getEntriesByType.bind(performance);
                        Object.defineProperty(prototype, "getEntriesByType", {
                            configurable: true,
                            writable: true,
                            value(type) {
                                if (type === "resource") {
                                    return entries;
                                }
                                return original(type);
                            }
                        });
                        const applied = performance.getEntriesByType("resource");
                        return {
                            count: Array.isArray(applied) ? applied.length : -1,
                            installed: Array.isArray(applied) && applied.length === entries.length
                        };
                    })(entries);
                    """,
                    arguments: [
                        "entries": entries
                    ],
                    in: nil,
                    contentWorld: .page
                )
                if let payload = result as? NSDictionary {
                    installed = (payload["installed"] as? Bool)
                        ?? ((payload["installed"] as? NSNumber)?.boolValue ?? false)
                }
            } catch {
                capturedError = error
            }
        }

        let waitResult = XCTWaiter().wait(for: [expectation], timeout: 5)
        XCTAssertEqual(waitResult, .completed, "Timed out while installing synthetic resource timings into the page.")
        if let capturedError {
            throw capturedError
        }
        XCTAssertTrue(installed, "The page did not accept the synthetic resource timing override.")
    }

    @MainActor
    func dismissPresentedInspector(from rootViewController: BrowserRootViewController) {
        rootViewController.presentedViewController?.dismiss(animated: false)
        let deadline = Date().addingTimeInterval(1)
        while rootViewController.presentedViewController != nil, Date() < deadline {
            drainMainQueue()
        }
        drainMainQueue()
    }

    @MainActor
    func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor
    func waitForCondition(
        description _: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            drainMainQueue()
        }
        return condition()
    }

    @MainActor
    func waitForNavigation(
        to url: URL,
        minimumDidFinishCount: Int,
        in store: BrowserStore,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.currentURL == url,
               store.didFinishNavigationCount >= minimumDidFinishCount,
               store.isLoading == false {
                return true
            }
            drainMainQueue()
        }
        return store.currentURL == url && store.didFinishNavigationCount >= minimumDidFinishCount
    }

    @MainActor
    func makeTemporaryHTMLURL(named name: String, title: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("\(name).html")
        let html = """
        <html>
            <head>
                <title>\(title)</title>
            </head>
            <body>
                <main>\(title)</main>
            </body>
        </html>
        """
        try html.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
#endif

#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import Monocly
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@_spi(Monocly) import WebInspectorTransport
@testable import WebInspectorUI

final class BrowserNavigationChromeTests: XCTestCase {
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
        XCTAssertTrue(pageViewController.backButtonItemForTesting.customView === pageViewController.backButtonForTesting)
        XCTAssertTrue(pageViewController.forwardButtonItemForTesting.customView === pageViewController.forwardButtonForTesting)
        XCTAssertFalse(pageViewController.backButtonForTesting.showsMenuAsPrimaryAction)
        XCTAssertFalse(pageViewController.forwardButtonForTesting.showsMenuAsPrimaryAction)
        XCTAssertNil(pageViewController.backButtonForTesting.menu)
        XCTAssertNil(pageViewController.forwardButtonForTesting.menu)
        XCTAssertEqual(pageViewController.backButtonItemForTesting.accessibilityIdentifier, "Monocly.navigation.back.compact")
        XCTAssertEqual(pageViewController.forwardButtonItemForTesting.accessibilityIdentifier, "Monocly.navigation.forward.compact")
        XCTAssertEqual(pageViewController.inspectorButtonItemForTesting.accessibilityIdentifier, "Monocly.openInspectorButton.compact")
    }

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
        XCTAssertTrue(pageViewController.backButtonItemForTesting.customView === pageViewController.backButtonForTesting)
        XCTAssertTrue(pageViewController.forwardButtonItemForTesting.customView === pageViewController.forwardButtonForTesting)
        XCTAssertFalse(pageViewController.backButtonForTesting.showsMenuAsPrimaryAction)
        XCTAssertFalse(pageViewController.forwardButtonForTesting.showsMenuAsPrimaryAction)
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
        let compactHost = try XCTUnwrap(inspectorContainer.activeHostViewControllerForTesting as? WICompactTabHostViewController)

        XCTAssertEqual(
            compactHost.displayedTabIdentifiersForTesting,
            ["wi_dom", "wi_element", "wi_network"]
        )

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testCompactInspectorReopenRestoresLastSelectedTopLevelTab() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)
        let firstInspector = try presentCompactInspector(from: pageViewController, rootViewController: rootViewController)
        let firstHost = try XCTUnwrap(firstInspector.activeHostViewControllerForTesting as? WICompactTabHostViewController)
        let domTab = try XCTUnwrap(firstHost.currentUITabsForTesting.first(where: { $0.identifier == "wi_dom" }))
        let elementTab = try XCTUnwrap(firstHost.currentUITabsForTesting.first(where: { $0.identifier == "wi_element" }))

        XCTAssertTrue(firstHost.tabBarController(firstHost, shouldSelectTab: elementTab))
        firstHost.selectedTab = elementTab
        firstHost.tabBarController(firstHost, didSelectTab: elementTab, previousTab: domTab)
        XCTAssertEqual(rootViewController.inspectorController.selectedTab?.identifier, "wi_element")

        dismissPresentedInspector(from: rootViewController)

        let secondInspector = try presentCompactInspector(from: pageViewController, rootViewController: rootViewController)
        let secondHost = try XCTUnwrap(secondInspector.activeHostViewControllerForTesting as? WICompactTabHostViewController)

        XCTAssertEqual(secondHost.selectedTab?.identifier, "wi_element")

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

        XCTAssertTrue(rootViewController.presentedViewController is WITabViewController)
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

        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WITabViewController)
        XCTAssertNotNil(inspectorContainer.presentationController?.delegate)

        dismissPresentedInspector(from: rootViewController)
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
                inspectorController: fixture.rootViewController.inspectorController,
                tabs: [.dom(), .network()]
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
    func testOpeningInspectorBootstrapsCurrentPageResourceTimings() throws {
        try WIBackendFactoryTesting.withPageAgentFallback(reason: "Monocly page-agent bootstrap regression") {
            let initialURL = try makeTemporaryHTMLURL(named: "network-bootstrap", title: "Network Bootstrap")
            let fixture = try makeHostedRootViewController(initialURL: initialURL)
            let rootViewController = fixture.rootViewController
            let pageViewController = fixture.pageViewController
            let inspectorController = rootViewController.inspectorController

            pageViewController.setSupportsMultipleScenesForTesting(true)
            applyHorizontalSizeClass(.regular, to: rootViewController)

            XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))
            try installSyntheticResourceTimings(
                [[
                    "decodedBodySize": 256,
                    "duration": 4,
                    "encodedBodySize": 128,
                    "initiatorType": "script",
                    "name": "https://example.com/bootstrap.js",
                    "requestMethod": "GET",
                    "responseStatus": 200,
                    "startTime": 12
                ]],
                on: rootViewController.store.webView
            )

            _ = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
            selectInspectorTab("wi_network", in: inspectorController)

            let bootstrapped = waitForCondition(description: "open inspector bootstraps existing page resources") {
                inspectorController.network.session.mode == .active
                    && inspectorController.network.store.entries.contains { $0.url == "https://example.com/bootstrap.js" }
            }
            XCTAssertTrue(
                bootstrapped,
                "Opening the inspector on the Network tab did not bootstrap the current page resource timings into the shared network store."
            )
        }
    }

    @MainActor
    func testDismissingCompactInspectorSuspendsControllerAndClearsNetworkStore() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "network-close", title: "Network Close")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorController = rootViewController.inspectorController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        _ = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspectorController)
        try seedNetworkStore(
            url: "https://example.com/seed-close",
            requestID: 701,
            into: inspectorController.network.store
        )

        let seeded = waitForCondition(description: "seed network entries before dismiss") {
            inspectorController.network.session.mode == .active
                && inspectorController.network.store.entries.contains { $0.url == "https://example.com/seed-close" }
        }
        XCTAssertTrue(seeded, "The regular inspector did not expose the seeded network store entry before dismiss.")

        dismissPresentedInspector(from: rootViewController)

        let suspendedAndCleared = waitForCondition(description: "dismiss compact inspector clears network store") {
            inspectorController.lifecycle == .suspended
                && inspectorController.network.session.mode == .stopped
                && inspectorController.network.store.entries.isEmpty
        }
        XCTAssertTrue(
            suspendedAndCleared,
            "Dismissing the compact inspector did not suspend the shared inspector controller and clear the network store."
        )
    }

    @MainActor
    func testReopeningCompactInspectorRebootstrapsCurrentPageNetworkEntries() throws {
        let initialURL = try makeTemporaryHTMLURL(named: "network-reopen", title: "Network Reopen")
        let fixture = try makeHostedRootViewController(initialURL: initialURL)
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController
        let inspectorController = rootViewController.inspectorController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        _ = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspectorController)
        try seedNetworkStore(
            url: "https://example.com/seed-reopen",
            requestID: 702,
            into: inspectorController.network.store
        )

        let firstSeed = waitForCondition(description: "seed network entry before reopen") {
            inspectorController.network.store.entries.contains { $0.url == "https://example.com/seed-reopen" }
        }
        XCTAssertTrue(firstSeed, "The first inspector presentation did not expose the seeded network entry.")

        dismissPresentedInspector(from: rootViewController)

        let cleared = waitForCondition(description: "network store clears after dismiss") {
            inspectorController.network.store.entries.isEmpty
                && inspectorController.network.session.mode == .stopped
        }
        XCTAssertTrue(cleared, "The shared inspector controller did not clear the network store after dismiss.")

        _ = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspectorController)
        let expectedFinishCount = rootViewController.store.didFinishNavigationCount + 1
        rootViewController.store.webView.reload()

        let rebound = waitForCondition(description: "fresh network capture after reopen") {
            inspectorController.lifecycle == .active
                && inspectorController.network.session.mode == .active
                && rootViewController.store.didFinishNavigationCount >= expectedFinishCount
                && inspectorController.network.store.entries.isEmpty == false
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
        let inspectorController = rootViewController.inspectorController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(waitForNavigation(to: initialURL, minimumDidFinishCount: 1, in: rootViewController.store))

        _ = try presentRegularInspector(from: pageViewController, rootViewController: rootViewController)
        selectInspectorTab("wi_network", in: inspectorController)
        try seedNetworkStore(
            url: "https://example.com/seed-switch",
            requestID: 703,
            into: inspectorController.network.store
        )

        let seeded = waitForCondition(description: "seed network entries before tab switch") {
            inspectorController.network.session.mode == .active
                && inspectorController.network.store.entries.contains { $0.url == "https://example.com/seed-switch" }
        }
        XCTAssertTrue(seeded, "The inspector did not expose the seeded network entry before switching tabs.")

        let bootstrappedEntryCount = inspectorController.network.store.entries.count
        selectInspectorTab("wi_dom", in: inspectorController)

        let switchedToDOM = waitForCondition(description: "switch to DOM without clearing network store") {
            inspectorController.lifecycle == .active
                && inspectorController.network.session.mode == .buffering
                && inspectorController.network.store.entries.count >= bootstrappedEntryCount
                && inspectorController.network.store.entries.contains { $0.url == "https://example.com/seed-switch" }
        }
        XCTAssertTrue(switchedToDOM, "Switching away from the Network tab cleared the network store while the inspector stayed open.")

        selectInspectorTab("wi_network", in: inspectorController)

        let switchedBack = waitForCondition(description: "switch back to network without clearing network store") {
            inspectorController.lifecycle == .active
                && inspectorController.network.session.mode == .active
                && inspectorController.network.store.entries.count >= bootstrappedEntryCount
                && inspectorController.network.store.entries.contains { $0.url == "https://example.com/seed-switch" }
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
        XCTAssertTrue(pageViewController.forwardButtonForTesting.menu != nil)
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
    ) throws -> WITabViewController {
        let buttonItem = pageViewController.inspectorButtonItemForTesting
        let action = try XCTUnwrap(buttonItem.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: buttonItem.target, from: buttonItem, for: nil))
        drainMainQueue()

        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WITabViewController)
        inspectorContainer.horizontalSizeClassOverrideForTesting = .compact
        inspectorContainer.loadViewIfNeeded()
        inspectorContainer.view.layoutIfNeeded()
        return inspectorContainer
    }

    @MainActor
    func presentRegularInspector(
        from pageViewController: BrowserPageViewController,
        rootViewController: BrowserRootViewController
    ) throws -> WITabViewController {
        XCTAssertTrue(pageViewController.triggerInspectorPrimaryActionForTesting())
        drainMainQueue()

        let inspectorContainer = try XCTUnwrap(rootViewController.presentedViewController as? WITabViewController)
        inspectorContainer.loadViewIfNeeded()
        inspectorContainer.view.layoutIfNeeded()
        return inspectorContainer
    }

    @MainActor
    func selectCompactInspectorTab(
        _ identifier: String,
        in inspectorContainer: WITabViewController
    ) throws {
        let compactHost = try XCTUnwrap(inspectorContainer.activeHostViewControllerForTesting as? WICompactTabHostViewController)
        let targetTab = try XCTUnwrap(compactHost.currentUITabsForTesting.first(where: { $0.identifier == identifier }))
        let previousTab = compactHost.selectedTab
        XCTAssertTrue(compactHost.tabBarController(compactHost, shouldSelectTab: targetTab))
        compactHost.selectedTab = targetTab
        compactHost.tabBarController(compactHost, didSelectTab: targetTab, previousTab: previousTab)
        drainMainQueue()
    }

    @MainActor
    func selectInspectorTab(_ identifier: String, in inspectorController: WIInspectorController) {
        let tab = inspectorController.tabs.first(where: { $0.identifier == identifier })
        inspectorController.setSelectedTab(tab)
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
                let result = try await webView.callAsyncJavaScript(
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

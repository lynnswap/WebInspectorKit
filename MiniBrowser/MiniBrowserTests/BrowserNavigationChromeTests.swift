#if os(iOS)
import UIKit
import XCTest
@testable import MiniBrowser
@testable import WebInspectorUI

final class BrowserNavigationChromeTests: XCTestCase {
    private var retainedWindows: [UIWindow] = []

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
        XCTAssertTrue(toolbarItems.contains { $0 === pageViewController.compactBackButtonItemForTesting })
        XCTAssertTrue(toolbarItems.contains { $0 === pageViewController.compactForwardButtonItemForTesting })
        XCTAssertTrue(toolbarItems.contains { $0 === pageViewController.compactInspectorButtonItemForTesting })
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
        XCTAssertTrue(leadingItems.contains { $0 === pageViewController.regularBackButtonItemForTesting })
        XCTAssertTrue(leadingItems.contains { $0 === pageViewController.regularForwardButtonItemForTesting })
        XCTAssertTrue(trailingItems.contains { $0 === pageViewController.regularInspectorButtonItemForTesting })
        XCTAssertTrue(pageViewController.regularInspectorHasPrimaryActionForTesting)
        XCTAssertEqual(
            pageViewController.regularInspectorMenuActionTitlesForTesting,
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
        XCTAssertFalse(pageViewController.compactBackButtonItemForTesting.isEnabled)
        XCTAssertFalse(pageViewController.compactForwardButtonItemForTesting.isEnabled)

        applyHorizontalSizeClass(.regular, to: rootViewController)
        XCTAssertEqual(pageViewController.chromePlacementForTesting, "regularNavigationBar")
        XCTAssertTrue(rootViewController.isToolbarHidden)
        XCTAssertEqual(pageViewController.navigationItem.title, "about:blank")
        XCTAssertFalse(pageViewController.regularBackButtonItemForTesting.isEnabled)
        XCTAssertFalse(pageViewController.regularForwardButtonItemForTesting.isEnabled)

        applyHorizontalSizeClass(.compact, to: rootViewController)
        XCTAssertEqual(pageViewController.chromePlacementForTesting, "compactToolbar")
        XCTAssertFalse(rootViewController.isToolbarHidden)
        XCTAssertEqual(pageViewController.navigationItem.title, "about:blank")
        XCTAssertEqual(pageViewController.navigationItem.leadingItemGroups.count, 0)
        XCTAssertEqual(pageViewController.navigationItem.trailingItemGroups.count, 0)
        XCTAssertFalse(pageViewController.compactBackButtonItemForTesting.isEnabled)
        XCTAssertFalse(pageViewController.compactForwardButtonItemForTesting.isEnabled)
    }

    @MainActor
    func testCompactToolbarContributesAdditionalBottomSafeArea() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        let windowSafeAreaBottom = rootViewController.view.window?.safeAreaInsets.bottom ?? 0
        XCTAssertGreaterThan(pageViewController.view.safeAreaInsets.bottom, windowSafeAreaBottom)
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
        XCTAssertTrue(pageViewController.regularInspectorButtonItemForTesting.isEnabled)

        XCTAssertTrue(pageViewController.triggerRegularInspectorPrimaryActionForTesting())
        drainMainQueue()

        XCTAssertTrue(rootViewController.presentedViewController is WITabViewController)
        XCTAssertFalse(pageViewController.regularInspectorButtonItemForTesting.isEnabled)

        dismissPresentedInspector(from: rootViewController)
    }

    @MainActor
    func testRegularInspectorSheetInstallsDismissDelegateOnPresentationController() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertTrue(pageViewController.triggerRegularInspectorPrimaryActionForTesting())
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

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.regular, to: rootViewController)
        pageViewController.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { userActivity, _, _ in
                    requestedActivity = userActivity
                    activationCount += 1
                }
            )
        )

        XCTAssertTrue(pageViewController.triggerRegularInspectorWindowActionForTesting())
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(requestedActivity?.activityType, BrowserInspectorCoordinator.inspectorWindowSceneActivityType)
        XCTAssertEqual(requestedActivity?.targetContentIdentifier, BrowserInspectorCoordinator.inspectorWindowSceneActivityType)

        XCTAssertTrue(pageViewController.hasInspectorWindowForTesting)
        XCTAssertFalse(pageViewController.regularInspectorButtonItemForTesting.isEnabled)

        XCTAssertFalse(pageViewController.triggerRegularInspectorWindowActionForTesting())
        XCTAssertEqual(activationCount, 1)
        pageViewController.dismissInspectorWindowForTesting()
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
    func testRegularInspectorUsesPlainButtonWhenMultipleScenesUnsupported() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(false)
        applyHorizontalSizeClass(.regular, to: rootViewController)

        XCTAssertFalse(pageViewController.regularInspectorHasPrimaryActionForTesting)
        XCTAssertTrue(pageViewController.regularInspectorMenuActionTitlesForTesting.isEmpty)
    }

    @MainActor
    func testCompactInspectorUsesMenuWhenMultipleScenesSupported() throws {
        let fixture = try makeHostedRootViewController()
        let rootViewController = fixture.rootViewController
        let pageViewController = fixture.pageViewController

        pageViewController.setSupportsMultipleScenesForTesting(true)
        applyHorizontalSizeClass(.compact, to: rootViewController)

        XCTAssertTrue(pageViewController.compactInspectorHasPrimaryActionForTesting)
        XCTAssertEqual(
            pageViewController.compactInspectorMenuActionTitlesForTesting,
            ["Open as Sheet", "Open in New Window"]
        )
    }
}

private extension BrowserNavigationChromeTests {
    @MainActor
    private func makeHostedRootViewController() throws -> HostedRootViewControllerFixture {
        let rootViewController = BrowserRootViewController(
            launchConfiguration: BrowserLaunchConfiguration(
                initialURL: URL(string: "about:blank")!
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
        let buttonItem = pageViewController.compactInspectorButtonItemForTesting
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
}
#endif

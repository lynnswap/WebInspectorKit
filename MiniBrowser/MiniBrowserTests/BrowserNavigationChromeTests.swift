#if os(iOS)
import UIKit
import XCTest
@testable import MiniBrowser

final class BrowserNavigationChromeTests: XCTestCase {
    @MainActor
    func testCompactSizeClassUsesBottomToolbar() throws {
        let (rootViewController, pageViewController) = try makeHostedRootViewController()

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
        let (rootViewController, pageViewController) = try makeHostedRootViewController()

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
    }

    @MainActor
    func testChromePlacementTransitionsBetweenCompactAndRegular() throws {
        let (rootViewController, pageViewController) = try makeHostedRootViewController()

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
}

private extension BrowserNavigationChromeTests {
    @MainActor
    func makeHostedRootViewController() throws -> (BrowserRootViewController, BrowserPageViewController) {
        let rootViewController = BrowserRootViewController(
            launchConfiguration: BrowserLaunchConfiguration(
                initialURL: URL(string: "about:blank")!
            )
        )
        let window = try makeWindow()
        addTeardownBlock { [window] in
            window.isHidden = true
            window.rootViewController = nil
        }
        window.rootViewController = rootViewController
        rootViewController.loadViewIfNeeded()
        rootViewController.beginAppearanceTransition(true, animated: false)
        window.isHidden = false
        window.makeKeyAndVisible()
        rootViewController.endAppearanceTransition()
        rootViewController.view.layoutIfNeeded()

        let pageViewController = try XCTUnwrap(rootViewController.pageViewControllerForTesting)
        pageViewController.loadViewIfNeeded()
        pageViewController.view.layoutIfNeeded()

        return (rootViewController, pageViewController)
    }

    @MainActor
    func makeWindow() throws -> UIWindow {
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
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
}
#endif

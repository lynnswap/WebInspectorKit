import XCTest
@testable import Monocly

#if os(iOS)
import UIKit
@testable import WebInspectorRuntime
@testable import WebInspectorUI

final class MonoclyLifecycleTests: XCTestCase {
    private var retainedWindows: [UIWindow] = []

    override func tearDown() {
        let windows = retainedWindows
        retainedWindows.removeAll()

        let cleanupExpectation = XCTestExpectation(description: "reset Monocly lifecycle state")
        Task { @MainActor in
            BrowserInspectorCoordinator.clearInspectorWindowPresentation()
            MonoclyWindowContextStore.shared.resetForTesting()
            windows.forEach {
                $0.isHidden = true
                $0.rootViewController = nil
            }
            cleanupExpectation.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [cleanupExpectation], timeout: 2), .completed)
        super.tearDown()
    }

    @MainActor
    func testAppDelegateUsesInspectorSceneDelegateForInspectorActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType
        )

        XCTAssertTrue(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
    }

    @MainActor
    func testAppDelegateUsesMainSceneDelegateForRegularActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            activityType: nil
        )

        XCTAssertTrue(configuration.delegateClass === MonoclyMainSceneDelegate.self)
    }

    @MainActor
    func testMainSceneDelegateConnectsWindowAndFinalizesRootOnDisconnect() throws {
        let sceneDelegate = MonoclyMainSceneDelegate()
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)

        sceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let hostWindow = try XCTUnwrap(sceneDelegate.window)
        retainedWindows.append(hostWindow)
        let rootViewController = try XCTUnwrap(sceneDelegate.rootViewController)
        XCTAssertTrue(hostWindow.rootViewController === rootViewController)

        sceneDelegate.sceneDidBecomeActive(windowScene)
        XCTAssertTrue(MonoclyWindowContextStore.shared.currentWindowScene === windowScene)
        XCTAssertTrue(MonoclyWindowContextStore.shared.currentWindow === hostWindow)

        sceneDelegate.disconnect(windowScene: windowScene)

        XCTAssertNil(sceneDelegate.window)
        XCTAssertNil(sceneDelegate.rootViewController)
        XCTAssertNil(MonoclyWindowContextStore.shared.currentWindowScene)
        XCTAssertNil(MonoclyWindowContextStore.shared.currentWindow)
        XCTAssertTrue(waitForCondition {
            rootViewController.inspectorController.lifecycle == .disconnected
        })
    }

    @MainActor
    func testInspectorSceneDelegateAttachesAndDetachesInspectorWindowSession() throws {
        let fixture = try makeHostedRootViewController()
        let coordinator = BrowserInspectorCoordinator()
        let sceneDelegate = MonoclyInspectorSceneDelegate()

        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, _ in }
            )
        )

        XCTAssertTrue(
            coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorController: fixture.rootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )
        XCTAssertTrue(coordinator.hasInspectorWindowForTesting)

        sceneDelegate.connect(windowScene: fixture.windowScene)

        let inspectorWindow = try XCTUnwrap(sceneDelegate.window)
        retainedWindows.append(inspectorWindow)
        XCTAssertTrue(inspectorWindow.rootViewController === sceneDelegate.inspectorViewController)
        XCTAssertTrue(coordinator.hasInspectorWindowForTesting)

        sceneDelegate.disconnect(windowScene: fixture.windowScene)

        XCTAssertNil(sceneDelegate.window)
        XCTAssertNil(sceneDelegate.inspectorViewController)
        XCTAssertFalse(coordinator.hasInspectorWindowForTesting)
    }
}

private extension MonoclyLifecycleTests {
    struct HostedRootFixture {
        let windowScene: UIWindowScene
        let rootViewController: BrowserRootViewController
    }

    @MainActor
    func makeHostedRootViewController() throws -> HostedRootFixture {
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        let rootViewController = BrowserRootViewController(launchConfiguration: launchConfiguration)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        retainedWindows.append(window)
        drainMainQueue()
        return HostedRootFixture(windowScene: windowScene, rootViewController: rootViewController)
    }

    @MainActor
    func makeWindowScene() throws -> UIWindowScene {
        try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
    }

    @MainActor
    func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @MainActor
    func waitForCondition(timeout: TimeInterval = 2, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            drainMainQueue()
        }
        return condition()
    }
}
#elseif os(macOS)
import AppKit

final class MonoclyLifecycleTests: XCTestCase {
    @MainActor
    private final class SpyMainWindowController: NSWindowController {
        var showWindowCallCount = 0

        override func showWindow(_ sender: Any?) {
            _ = sender
            if window == nil {
                window = NSWindow(contentViewController: NSViewController())
            }
            showWindowCallCount += 1
        }
    }

    private var retainedWindows: [NSWindow] = []

    override func tearDown() {
        let windows = retainedWindows
        retainedWindows.removeAll()

        let cleanupExpectation = XCTestExpectation(description: "tear down Monocly lifecycle windows")
        Task { @MainActor in
            windows.forEach {
                $0.orderOut(nil)
                $0.contentViewController = nil
                $0.close()
            }
            MonoclyWindowContextStore.shared.resetForTesting()
            cleanupExpectation.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [cleanupExpectation], timeout: 2), .completed)
        super.tearDown()
    }

    @MainActor
    func testAppDelegateShowsMainWindowOnLaunchAndReopenUsingSameController() {
        let spyController = SpyMainWindowController()
        var factoryCallCount = 0
        let delegate = MonoclyAppDelegate { _ in
            factoryCallCount += 1
            return spyController
        }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(spyController.showWindowCallCount, 1)
        retainedWindows.append(spyController.window!)

        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(spyController.showWindowCallCount, 2)

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(spyController.showWindowCallCount, 2)
    }

    @MainActor
    func testMainWindowControllerReplacesRootControllerAfterClose() throws {
        let controller = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )

        controller.showWindow(nil)

        let window = try XCTUnwrap(controller.window)
        retainedWindows.append(window)
        let firstRootViewController = try XCTUnwrap(window.contentViewController as? BrowserRootViewController)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        controller.showWindow(nil)

        let secondRootViewController = try XCTUnwrap(window.contentViewController as? BrowserRootViewController)
        XCTAssertFalse(firstRootViewController === secondRootViewController)
    }
}
#endif

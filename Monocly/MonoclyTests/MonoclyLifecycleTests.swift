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
            existingConfigurationName: nil,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType
        )

        XCTAssertTrue(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
    }

    @MainActor
    func testAppDelegateUsesMainSceneDelegateForRegularActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: nil,
            activityType: nil
        )

        XCTAssertTrue(configuration.delegateClass === MonoclyMainSceneDelegate.self)
    }

    @MainActor
    func testAppDelegateKeepsInspectorSceneDelegateForRestoredInspectorSession() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
            activityType: nil
        )

        XCTAssertTrue(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
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
                activateScene: { _, _, _, _ in }
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

        sceneDelegate.scene(
            fixture.windowScene,
            continue: NSUserActivity(activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType)
        )
        XCTAssertTrue(coordinator.hasInspectorWindowForTesting)

        sceneDelegate.disconnect(windowScene: fixture.windowScene)

        XCTAssertNil(sceneDelegate.window)
        XCTAssertNil(sceneDelegate.inspectorViewController)
        XCTAssertFalse(coordinator.hasInspectorWindowForTesting)
    }

    @MainActor
    func testInspectorSceneDelegateDestroysOrphanedRestoredSessionWithoutContext() throws {
        let windowScene = try makeWindowScene()
        let sceneDelegate = MonoclyInspectorSceneDelegate()
        var destroyedSceneSession: UISceneSession?

        MonoclyInspectorSceneDelegate.setSceneDestructionRequesterForTesting(
            BrowserInspectorSceneDestructionRequester { sceneSession in
                destroyedSceneSession = sceneSession
            }
        )
        addTeardownBlock {
            Task { @MainActor in
                MonoclyInspectorSceneDelegate.resetSceneDestructionRequesterForTesting()
            }
        }

        sceneDelegate.connect(windowScene: windowScene)

        XCTAssertTrue(destroyedSceneSession === windowScene.session)
        XCTAssertNil(sceneDelegate.window)
        XCTAssertNil(sceneDelegate.inspectorViewController)
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
@testable import WebInspectorUI

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
            window?.orderFront(nil)
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
        let previousMainMenu = NSApp.mainMenu
        addTeardownBlock {
            NSApp.mainMenu = previousMainMenu
        }
        let delegate = MonoclyAppDelegate { _ in
            factoryCallCount += 1
            return spyController
        }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(spyController.showWindowCallCount, 1)
        XCTAssertEqual(NSApp.mainMenu?.items.first?.submenu?.items.last?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Close Window")?.keyEquivalent, "w")
        XCTAssertEqual(NSApp.windowsMenu?.item(withTitle: "Minimize")?.keyEquivalent, "m")
        retainedWindows.append(spyController.window!)

        spyController.window?.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(spyController.showWindowCallCount, 2)

        let inspectorWindow = NSWindow(contentViewController: NSViewController())
        inspectorWindow.orderFront(nil)
        retainedWindows.append(inspectorWindow)
        spyController.window?.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(spyController.showWindowCallCount, 3)

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(spyController.showWindowCallCount, 3)
    }

    @MainActor
    func testNewWindowMenuCreatesAdditionalMainWindowController() throws {
        var controllers: [SpyMainWindowController] = []
        let previousMainMenu = NSApp.mainMenu
        addTeardownBlock {
            NSApp.mainMenu = previousMainMenu
        }
        let delegate = MonoclyAppDelegate { _ in
            let controller = SpyMainWindowController()
            controllers.append(controller)
            return controller
        }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let newWindowItem = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Window"))
        XCTAssertTrue(NSApp.sendAction(newWindowItem.action!, to: newWindowItem.target, from: newWindowItem))

        XCTAssertEqual(controllers.count, 2)
        XCTAssertEqual(controllers[0].showWindowCallCount, 1)
        XCTAssertEqual(controllers[1].showWindowCallCount, 1)
        retainedWindows.append(try XCTUnwrap(controllers[0].window))
        retainedWindows.append(try XCTUnwrap(controllers[1].window))
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
        XCTAssertNil(window.contentViewController)
        controller.showWindow(nil)

        let secondRootViewController = try XCTUnwrap(window.contentViewController as? BrowserRootViewController)
        XCTAssertFalse(firstRootViewController === secondRootViewController)
    }

    @MainActor
    func testMainWindowControllerPreservesInspectorSessionAcrossReopenWhenInspectorIsVisible() throws {
        let controller = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )

        controller.showWindow(nil)

        let mainWindow = try XCTUnwrap(controller.window)
        retainedWindows.append(mainWindow)
        let firstRootViewController = try XCTUnwrap(mainWindow.contentViewController as? BrowserRootViewController)

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: mainWindow,
                browserStore: firstRootViewController.store,
                inspectorController: firstRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        retainedWindows.append(inspectorWindow)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: mainWindow))
        XCTAssertNil(mainWindow.contentViewController)
        controller.showWindow(nil)

        let reopenedRootViewController = try XCTUnwrap(mainWindow.contentViewController as? BrowserRootViewController)
        XCTAssertTrue(firstRootViewController === reopenedRootViewController)
    }

    @MainActor
    func testMainWindowControllerPreservesInspectorSessionAcrossReopenWhenInspectorIsHidden() throws {
        let controller = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )

        controller.showWindow(nil)

        let mainWindow = try XCTUnwrap(controller.window)
        retainedWindows.append(mainWindow)
        let firstRootViewController = try XCTUnwrap(mainWindow.contentViewController as? BrowserRootViewController)

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: mainWindow,
                browserStore: firstRootViewController.store,
                inspectorController: firstRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        retainedWindows.append(inspectorWindow)
        inspectorWindow.orderOut(nil)
        XCTAssertFalse(inspectorWindow.isVisible)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: mainWindow))
        controller.showWindow(nil)

        let reopenedRootViewController = try XCTUnwrap(mainWindow.contentViewController as? BrowserRootViewController)
        XCTAssertTrue(firstRootViewController === reopenedRootViewController)
    }

    @MainActor
    func testMainWindowControllerDropsPreservedSessionWhenInspectorClosesBeforeReopen() throws {
        let controller = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )

        controller.showWindow(nil)

        let mainWindow = try XCTUnwrap(controller.window)
        retainedWindows.append(mainWindow)
        let firstRootViewController = try XCTUnwrap(mainWindow.contentViewController as? BrowserRootViewController)

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: mainWindow,
                browserStore: firstRootViewController.store,
                inspectorController: firstRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        retainedWindows.append(inspectorWindow)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: mainWindow))
        inspectorWindow.close()

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.showWindow(nil)

        let reopenedRootViewController = try XCTUnwrap(mainWindow.contentViewController as? BrowserRootViewController)
        XCTAssertFalse(firstRootViewController.store === reopenedRootViewController.store)
        XCTAssertFalse(firstRootViewController.inspectorController === reopenedRootViewController.inspectorController)
    }
}
#endif

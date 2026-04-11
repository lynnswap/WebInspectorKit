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
    func testMainSceneDelegateRetainsRootUntilDisconnectFinalizationCompletes() throws {
        let sceneDelegate = MonoclyMainSceneDelegate()
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        weak var weakRootViewController: BrowserRootViewController?
        var inspectorController: WIInspectorController?
        var didEnterDisconnectedCommit = false
        var resumeDisconnectedCommit: CheckedContinuation<Void, Never>?

        sceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let hostWindow = try XCTUnwrap(sceneDelegate.window)
        retainedWindows.append(hostWindow)

        do {
            let rootViewController = try XCTUnwrap(sceneDelegate.rootViewController)
            weakRootViewController = rootViewController
            inspectorController = rootViewController.inspectorController
            rootViewController.inspectorController.testRuntimeLifecycleCommitHook = { lifecycle in
                guard lifecycle == .disconnected else {
                    return
                }
                didEnterDisconnectedCommit = true
                await withCheckedContinuation { continuation in
                    resumeDisconnectedCommit = continuation
                }
            }

            sceneDelegate.disconnect(windowScene: windowScene)
        }

        XCTAssertTrue(waitForCondition {
            didEnterDisconnectedCommit
        })
        XCTAssertNotNil(weakRootViewController)

        resumeDisconnectedCommit?.resume()

        XCTAssertTrue(waitForCondition {
            inspectorController?.lifecycle == .disconnected
        })
    }

    @MainActor
    func testMainSceneDelegatePreservesInspectorSessionWhileInspectorSceneIsConnected() throws {
        let mainSceneDelegate = MonoclyMainSceneDelegate()
        let inspectorSceneDelegate = MonoclyInspectorSceneDelegate()
        let coordinator = BrowserInspectorCoordinator()
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)

        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, _, _ in }
            )
        )

        mainSceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let mainWindow = try XCTUnwrap(mainSceneDelegate.window)
        retainedWindows.append(mainWindow)
        let rootViewController = try XCTUnwrap(mainSceneDelegate.rootViewController)

        XCTAssertTrue(
            coordinator.presentWindow(
                from: rootViewController,
                browserStore: rootViewController.store,
                inspectorController: rootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        inspectorSceneDelegate.connect(windowScene: windowScene)

        let inspectorWindow = try XCTUnwrap(inspectorSceneDelegate.window)
        retainedWindows.append(inspectorWindow)

        mainSceneDelegate.disconnect(windowScene: windowScene)

        XCTAssertNil(mainSceneDelegate.window)
        XCTAssertNil(mainSceneDelegate.rootViewController)
        XCTAssertTrue(waitForCondition {
            rootViewController.inspectorController.lifecycle == .suspended
        })

        BrowserInspectorCoordinator.handleInspectorWindowSceneSessionsDidDiscard([windowScene.session])

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
    func testInspectorSceneDisconnectKeepsContextUntilSessionIsDiscarded() throws {
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

        sceneDelegate.connect(windowScene: fixture.windowScene)
        sceneDelegate.disconnect(windowScene: fixture.windowScene)

        XCTAssertTrue(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session))

        BrowserInspectorCoordinator.handleInspectorWindowSceneSessionsDidDiscard([fixture.windowScene.session])

        XCTAssertFalse(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session))
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

    @MainActor
    func testOrphanedInspectorSceneActivationDoesNotPolluteWindowRegistry() throws {
        let orphanWindowScene = try makeWindowScene()
        let sceneDelegate = MonoclyInspectorSceneDelegate()

        MonoclyInspectorSceneDelegate.setSceneDestructionRequesterForTesting(
            BrowserInspectorSceneDestructionRequester { _ in }
        )
        addTeardownBlock {
            Task { @MainActor in
                MonoclyInspectorSceneDelegate.resetSceneDestructionRequesterForTesting()
            }
        }

        sceneDelegate.connect(windowScene: orphanWindowScene)
        sceneDelegate.sceneDidBecomeActive(orphanWindowScene)

        let fixture = try makeHostedRootViewController()
        let coordinator = BrowserInspectorCoordinator()
        var activatedSceneSession: UISceneSession?

        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { sceneSession, _, _, _ in
                    activatedSceneSession = sceneSession
                }
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

        XCTAssertNil(activatedSceneSession)
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
        XCTAssertEqual(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Paste")?.action, #selector(NSText.paste(_:)))
        XCTAssertEqual(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Select All")?.keyEquivalent, "a")
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

        controllers[0].window?.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(controllers[0].showWindowCallCount, 1)
        XCTAssertEqual(controllers[1].showWindowCallCount, 1)
    }

    @MainActor
    func testInspectorCloseHandlerStaysScopedToPresentingMainWindowController() throws {
        let firstController = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )
        let secondController = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )

        firstController.showWindow(nil)
        secondController.showWindow(nil)

        let firstWindow = try XCTUnwrap(firstController.window)
        let secondWindow = try XCTUnwrap(secondController.window)
        retainedWindows.append(firstWindow)
        retainedWindows.append(secondWindow)
        let firstRootViewController = try XCTUnwrap(firstWindow.contentViewController as? BrowserRootViewController)

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: firstWindow,
                browserStore: firstRootViewController.store,
                inspectorController: firstRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        retainedWindows.append(inspectorWindow)

        firstController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))
        inspectorWindow.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        firstController.showWindow(nil)

        let reopenedRootViewController = try XCTUnwrap(firstWindow.contentViewController as? BrowserRootViewController)
        XCTAssertFalse(firstRootViewController === reopenedRootViewController)
    }

    @MainActor
    func testRetainedRootIsReleasedWhenInspectorSwitchesToAnotherMainWindowController() throws {
        let firstController = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )
        let secondController = MonoclyMainWindowController(
            launchConfiguration: BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        )

        firstController.showWindow(nil)
        secondController.showWindow(nil)

        let firstWindow = try XCTUnwrap(firstController.window)
        let secondWindow = try XCTUnwrap(secondController.window)
        retainedWindows.append(firstWindow)
        retainedWindows.append(secondWindow)
        let firstRootViewController = try XCTUnwrap(firstWindow.contentViewController as? BrowserRootViewController)
        let secondRootViewController = try XCTUnwrap(secondWindow.contentViewController as? BrowserRootViewController)

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: firstWindow,
                browserStore: firstRootViewController.store,
                inspectorController: firstRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        retainedWindows.append(inspectorWindow)

        firstController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: secondWindow,
                browserStore: secondRootViewController.store,
                inspectorController: secondRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        firstController.showWindow(nil)

        let reopenedRootViewController = try XCTUnwrap(firstWindow.contentViewController as? BrowserRootViewController)
        XCTAssertFalse(firstRootViewController === reopenedRootViewController)
    }

    @MainActor
    func testAdditionalMainWindowControllerStaysRetainedWhileItsInspectorIsOpen() throws {
        var controllers: [MonoclyMainWindowController] = []
        let previousMainMenu = NSApp.mainMenu
        addTeardownBlock {
            NSApp.mainMenu = previousMainMenu
        }
        let delegate = MonoclyAppDelegate { launchConfiguration in
            let controller = MonoclyMainWindowController(launchConfiguration: launchConfiguration)
            controllers.append(controller)
            return controller
        }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        let newWindowItem = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Window"))
        XCTAssertTrue(NSApp.sendAction(newWindowItem.action!, to: newWindowItem.target, from: newWindowItem))
        XCTAssertEqual(delegate.additionalWindowControllerCountForTesting, 1)

        let primaryWindow = try XCTUnwrap(controllers.first?.window)
        let secondaryController = try XCTUnwrap(controllers.last)
        let secondaryWindow = try XCTUnwrap(secondaryController.window)
        retainedWindows.append(primaryWindow)
        retainedWindows.append(secondaryWindow)
        let secondaryRootViewController = try XCTUnwrap(secondaryWindow.contentViewController as? BrowserRootViewController)

        XCTAssertTrue(
            BrowserInspectorCoordinator.present(
                from: secondaryWindow,
                browserStore: secondaryRootViewController.store,
                inspectorController: secondaryRootViewController.inspectorController,
                tabs: [.dom(), .network()]
            )
        )

        let inspectorWindow = try XCTUnwrap(
            NSApp.windows.first { $0.title == "Web Inspector" && $0.isVisible }
        )
        retainedWindows.append(inspectorWindow)

        secondaryWindow.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(delegate.additionalWindowControllerCountForTesting, 1)
        XCTAssertTrue(secondaryController.isRetainingInspectorSessionAfterWindowClosure)

        inspectorWindow.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(delegate.additionalWindowControllerCountForTesting, 0)
        XCTAssertFalse(secondaryController.isRetainingInspectorSessionAfterWindowClosure)
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

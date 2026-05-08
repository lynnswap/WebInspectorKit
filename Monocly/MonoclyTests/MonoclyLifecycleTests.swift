import XCTest
@testable import Monocly

#if os(iOS)
import UIKit
@_spi(Monocly) import WebInspectorRuntime
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
    func testLegacySceneStateRecoveryRemovesSavedStateWhenSwiftUIMarkersExist() throws {
        let savedStateDirectoryURL = try makeSavedStateFixture(
            knownSceneSessionData: Data("SwiftUI.AppSceneDelegate".utf8),
            userInfoData: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>com.apple.SwiftUI.sceneID</key>
            <string>Monocly.ContentView-1</string>
            </dict>
            </plist>
            """.utf8)
        )

        XCTAssertTrue(try MonoclyLegacySceneStateRecovery.recoverIfNeeded(savedStateDirectoryURL: savedStateDirectoryURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedStateDirectoryURL.path))
    }

    @MainActor
    func testLegacySceneStateRecoveryPreservesUIKitSavedState() throws {
        let savedStateDirectoryURL = try makeSavedStateFixture(
            knownSceneSessionData: Data("Monocly.MonoclyMainSceneDelegate".utf8),
            userInfoData: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>MonoclyScene</key>
            <string>Main</string>
            </dict>
            </plist>
            """.utf8)
        )

        XCTAssertFalse(try MonoclyLegacySceneStateRecovery.recoverIfNeeded(savedStateDirectoryURL: savedStateDirectoryURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedStateDirectoryURL.path))
    }

    @MainActor
    func testAppDelegateSkipsLegacyRecoveryWhenMultipleScenesSupported() throws {
        let savedStateDirectoryURL = try makeSavedStateFixture(
            knownSceneSessionData: Data("SwiftUI.AppSceneDelegate".utf8),
            userInfoData: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>com.apple.SwiftUI.sceneID</key>
            <string>Monocly.ContentView-1</string>
            </dict>
            </plist>
            """.utf8)
        )
        let delegate = MonoclyAppDelegate()

        XCTAssertFalse(
            delegate.recoverLegacySceneStateIfNeeded(
                supportsMultipleScenes: true,
                savedStateDirectoryURL: savedStateDirectoryURL
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedStateDirectoryURL.path))
    }

    @MainActor
    func testAppDelegateUsesInspectorSceneDelegateAndWindowSceneForInspectorActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: nil,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
            supportsMultipleScenes: true
        )

        XCTAssertEqual(configuration.name, MonoclyAppDelegate.inspectorSceneConfigurationName)
        XCTAssertTrue(configuration.sceneClass === UIWindowScene.self)
        XCTAssertTrue(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
    }

    @MainActor
    func testAppDelegateUsesMainSceneDelegateAndWindowSceneForRegularActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: nil,
            activityType: nil,
            supportsMultipleScenes: false
        )

        XCTAssertEqual(configuration.name, MonoclyAppDelegate.mainSceneConfigurationName)
        XCTAssertTrue(configuration.sceneClass === UIWindowScene.self)
        XCTAssertTrue(configuration.delegateClass === MonoclyMainSceneDelegate.self)
    }

    @MainActor
    func testAppDelegateKeepsInspectorSceneDelegateAndWindowSceneForRestoredInspectorSession() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
            activityType: nil,
            supportsMultipleScenes: true
        )

        XCTAssertEqual(configuration.name, MonoclyAppDelegate.inspectorSceneConfigurationName)
        XCTAssertTrue(configuration.sceneClass === UIWindowScene.self)
        XCTAssertTrue(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
    }

    @MainActor
    func testAppDelegateFallsBackToMainSceneWhenMultipleScenesUnsupported() {
        let inspectorActivityConfiguration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: nil,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
            supportsMultipleScenes: false
        )
        let restoredInspectorConfiguration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
            activityType: nil,
            supportsMultipleScenes: false
        )

        for configuration in [inspectorActivityConfiguration, restoredInspectorConfiguration] {
            XCTAssertEqual(configuration.name, MonoclyAppDelegate.mainSceneConfigurationName)
            XCTAssertTrue(configuration.sceneClass === UIWindowScene.self)
            XCTAssertTrue(configuration.delegateClass === MonoclyMainSceneDelegate.self)
        }
    }

    @MainActor
    func testAppDelegateForcesMainSceneDuringLegacyRecovery() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
            supportsMultipleScenes: true,
            forceMainSceneConfiguration: true
        )

        XCTAssertEqual(configuration.name, MonoclyAppDelegate.mainSceneConfigurationName)
        XCTAssertTrue(configuration.sceneClass === UIWindowScene.self)
        XCTAssertTrue(configuration.delegateClass === MonoclyMainSceneDelegate.self)
    }

    @MainActor
    func testPresentWindowFailsWithoutMultipleSceneSupport() throws {
        let fixture = try makeHostedRootViewController()
        let coordinator = BrowserInspectorCoordinator()
        var activationCount = 0

        coordinator.setSupportsMultipleScenesProviderForTesting { false }
        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, _, _ in
                    activationCount += 1
                }
            )
        )

        XCTAssertFalse(
            coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorRuntime: fixture.rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
            )
        )
        XCTAssertEqual(activationCount, 0)
        XCTAssertFalse(coordinator.hasInspectorWindowForTesting)
    }

    @MainActor
    func testLegacySceneRecoveryLeavesConnectedMainSessionAlive() throws {
        let windowScene = try makeWindowScene()
        let delegate = MonoclyAppDelegate()
        var destroyedSceneSessions: [UISceneSession] = []

        delegate.setLegacySceneRecoveryEnvironmentForTesting(
            MonoclyLegacySceneRecoveryEnvironment(
                openSessions: { [windowScene.session] },
                destroySceneSession: { destroyedSceneSessions.append($0) }
            )
        )
        delegate.setDidRecoverLegacySceneStateForTesting(true)
        delegate.handleLegacySceneRecoveryAfterMainSceneConnectedForTesting(windowScene)

        XCTAssertTrue(destroyedSceneSessions.isEmpty)
    }

    @MainActor
    func testLegacySceneRecoveryComputesStaleSessionIdentifiers() {
        let staleSessionIdentifiers = MonoclyAppDelegate.staleRecoveredSessionIdentifiers(
            openSessionIdentifiers: ["main-session", "stale-session-a", "stale-session-b"],
            connectedMainSessionIdentifier: "main-session"
        )

        XCTAssertEqual(staleSessionIdentifiers, ["stale-session-a", "stale-session-b"])
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
            rootViewController.inspectorRuntime.dom.hasPageWebViewForDiagnostics == false
        })
    }

    @MainActor
    func testMainSceneDelegateRetainsRootUntilRuntimeDetachCompletes() throws {
        let sceneDelegate = MonoclyMainSceneDelegate()
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        weak var weakRootViewController: BrowserRootViewController?
        var inspectorRuntime: WIRuntimeSession?

        sceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let hostWindow = try XCTUnwrap(sceneDelegate.window)
        retainedWindows.append(hostWindow)

        do {
            let rootViewController = try XCTUnwrap(sceneDelegate.rootViewController)
            weakRootViewController = rootViewController
            inspectorRuntime = rootViewController.inspectorRuntime

            sceneDelegate.disconnect(windowScene: windowScene)
        }

        XCTAssertNotNil(weakRootViewController)
        XCTAssertTrue(waitForCondition {
            inspectorRuntime?.dom.hasPageWebViewForDiagnostics == false
        })
    }

    @MainActor
    func testMainSceneDelegatePreservesInspectorSessionWhileInspectorSceneIsConnected() throws {
        let mainSceneDelegate = MonoclyMainSceneDelegate()
        let inspectorSceneDelegate = MonoclyInspectorSceneDelegate()
        let coordinator = BrowserInspectorCoordinator()
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)

        coordinator.setSupportsMultipleScenesProviderForTesting { true }
        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, _, _ in }
            )
        )

        mainSceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let mainWindow = try XCTUnwrap(mainSceneDelegate.window)
        retainedWindows.append(mainWindow)
        let rootViewController = try XCTUnwrap(mainSceneDelegate.rootViewController)
        let presentationWebView = rootViewController.inspectorRuntime.dom.treeWebViewForPresentation()

        XCTAssertTrue(
            coordinator.presentWindow(
                from: rootViewController,
                browserStore: rootViewController.store,
                inspectorRuntime: rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
            )
        )

        inspectorSceneDelegate.connect(windowScene: windowScene)

        let inspectorWindow = try XCTUnwrap(inspectorSceneDelegate.window)
        retainedWindows.append(inspectorWindow)

        mainSceneDelegate.disconnect(windowScene: windowScene)

        XCTAssertNil(mainSceneDelegate.window)
        XCTAssertNil(mainSceneDelegate.rootViewController)
        XCTAssertTrue(waitForCondition {
            BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorRuntime)
                && rootViewController.inspectorRuntime.dom.hasPageWebViewForDiagnostics == false
                && rootViewController.inspectorRuntime.dom.treeWebViewForPresentation() === presentationWebView
        })

        inspectorSceneDelegate.disconnect(windowScene: windowScene)

        XCTAssertTrue(waitForCondition {
            BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorRuntime) == false
                && rootViewController.inspectorRuntime.dom.hasPageWebViewForDiagnostics == false
                && rootViewController.inspectorRuntime.dom.treeWebViewForPresentation() !== presentationWebView
        })
    }

    @MainActor
    func testMainSceneDelegateReusesPreservedRootWhenSceneReconnects() throws {
        let mainSceneDelegate = MonoclyMainSceneDelegate()
        let inspectorSceneDelegate = MonoclyInspectorSceneDelegate()
        let coordinator = BrowserInspectorCoordinator()
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)

        coordinator.setSupportsMultipleScenesProviderForTesting { true }
        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, _, _ in }
            )
        )

        mainSceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let firstWindow = try XCTUnwrap(mainSceneDelegate.window)
        retainedWindows.append(firstWindow)
        let firstRootViewController = try XCTUnwrap(mainSceneDelegate.rootViewController)

        XCTAssertTrue(
            coordinator.presentWindow(
                from: firstRootViewController,
                browserStore: firstRootViewController.store,
                inspectorRuntime: firstRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
            )
        )

        inspectorSceneDelegate.connect(windowScene: windowScene)
        retainedWindows.append(try XCTUnwrap(inspectorSceneDelegate.window))

        mainSceneDelegate.disconnect(windowScene: windowScene)
        mainSceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

        let reconnectedWindow = try XCTUnwrap(mainSceneDelegate.window)
        retainedWindows.append(reconnectedWindow)
        let reconnectedRootViewController = try XCTUnwrap(mainSceneDelegate.rootViewController)

        XCTAssertTrue(firstRootViewController === reconnectedRootViewController)
    }

    @MainActor
    func testInspectorSceneDelegateAttachesAndDetachesInspectorWindowSession() throws {
        let fixture = try makeHostedRootViewController()
        let coordinator = BrowserInspectorCoordinator()
        let sceneDelegate = MonoclyInspectorSceneDelegate()

        coordinator.setSupportsMultipleScenesProviderForTesting { true }
        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { _, _, _, _ in }
            )
        )

        XCTAssertTrue(
            coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorRuntime: fixture.rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
    func testInspectorSceneDisconnectAllowsImmediateSessionReuseWhilePending() throws {
        let fixture = try makeHostedRootViewController()
        let coordinator = BrowserInspectorCoordinator()
        let sceneDelegate = MonoclyInspectorSceneDelegate()
        var activatedSceneSession: UISceneSession?
        var destroyedSceneSession: UISceneSession?

        coordinator.setSupportsMultipleScenesProviderForTesting { true }
        coordinator.setSceneActivationRequesterForTesting(
            BrowserInspectorSceneActivationRequester(
                activateScene: { sceneSession, _, _, _ in
                    activatedSceneSession = sceneSession
                }
            )
        )
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

        XCTAssertTrue(
            coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorRuntime: fixture.rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
            )
        )

        sceneDelegate.connect(windowScene: fixture.windowScene)
        sceneDelegate.disconnect(windowScene: fixture.windowScene)

        XCTAssertFalse(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session))

        XCTAssertTrue(
            coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorRuntime: fixture.rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
            )
        )
        XCTAssertTrue(coordinator.hasInspectorWindowForTesting)
        XCTAssertTrue(activatedSceneSession === fixture.windowScene.session)
        XCTAssertTrue(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session))

        sceneDelegate.connect(windowScene: fixture.windowScene)
        XCTAssertNil(destroyedSceneSession)
        XCTAssertNotNil(sceneDelegate.window)
        XCTAssertTrue(coordinator.hasInspectorWindowForTesting)

        sceneDelegate.disconnect(windowScene: fixture.windowScene)
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

        coordinator.setSupportsMultipleScenesProviderForTesting { true }
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
                inspectorRuntime: fixture.rootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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

    func makeSavedStateFixture(
        knownSceneSessionData: Data,
        userInfoData: Data,
        sceneData: Data = Data("SceneState".utf8)
    ) throws -> URL {
        let rootDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoclySavedState-\(UUID().uuidString)", isDirectory: true)
        let savedStateDirectoryURL = rootDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("lynnpd.Monocly.savedState", isDirectory: true)
        let sceneDirectoryURL = savedStateDirectoryURL
            .appendingPathComponent("3D56A58A-9EA8-4124-B116-56125EBB0D46", isDirectory: true)
        let knownSceneSessionsDirectoryURL = savedStateDirectoryURL
            .appendingPathComponent("KnownSceneSessions", isDirectory: true)

        try FileManager.default.createDirectory(at: sceneDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: knownSceneSessionsDirectoryURL, withIntermediateDirectories: true)
        try knownSceneSessionData.write(to: knownSceneSessionsDirectoryURL.appendingPathComponent("data.data"))
        try userInfoData.write(to: sceneDirectoryURL.appendingPathComponent("userInfo.data"))
        try sceneData.write(to: sceneDirectoryURL.appendingPathComponent("data.data"))

        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootDirectoryURL)
        }

        return savedStateDirectoryURL
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
                inspectorRuntime: firstRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
                inspectorRuntime: firstRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
                inspectorRuntime: secondRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
                inspectorRuntime: secondaryRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
                inspectorRuntime: firstRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
                inspectorRuntime: firstRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
                inspectorRuntime: firstRootViewController.inspectorRuntime,
                tabs: [.dom, .network]
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
        XCTAssertFalse(firstRootViewController.inspectorRuntime === reopenedRootViewController.inspectorRuntime)
    }
}
#endif

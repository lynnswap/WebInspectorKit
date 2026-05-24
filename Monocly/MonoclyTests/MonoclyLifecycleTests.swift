import Testing
@testable import Monocly

#if os(iOS)
import UIKit

@Suite(.serialized)
@MainActor
struct MonoclyLifecycleTests {
    @Test
    func legacySceneStateRecoveryRemovesSwiftUISavedState() throws {
        try withCleanState { context in
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
                """.utf8),
                context: context
            )

            let didRecover = try MonoclyLegacySceneStateRecovery.recoverIfNeeded(
                savedStateDirectoryURL: savedStateDirectoryURL
            )
            #expect(didRecover)
            #expect(FileManager.default.fileExists(atPath: savedStateDirectoryURL.path) == false)
        }
    }

    @Test
    func legacySceneStateRecoveryPreservesUIKitSavedState() throws {
        try withCleanState { context in
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
                """.utf8),
                context: context
            )

            let didRecover = try MonoclyLegacySceneStateRecovery.recoverIfNeeded(
                savedStateDirectoryURL: savedStateDirectoryURL
            )
            #expect(didRecover == false)
            #expect(FileManager.default.fileExists(atPath: savedStateDirectoryURL.path))
        }
    }

    @Test
    func appDelegateSkipsLegacyRecoveryWhenMultipleScenesAreSupported() throws {
        try withCleanState { context in
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
                """.utf8),
                context: context
            )
            let delegate = MonoclyAppDelegate()

            let didRecover = delegate.recoverLegacySceneStateIfNeeded(
                supportsMultipleScenes: true,
                savedStateDirectoryURL: savedStateDirectoryURL
            )
            #expect(didRecover == false)
            #expect(FileManager.default.fileExists(atPath: savedStateDirectoryURL.path))
        }
    }

    @Test
    func appDelegateUsesInspectorSceneForInspectorActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: nil,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
            supportsMultipleScenes: true
        )

        #expect(configuration.name == MonoclyAppDelegate.inspectorSceneConfigurationName)
        #expect(configuration.sceneClass === UIWindowScene.self)
        #expect(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
    }

    @Test
    func appDelegateUsesMainSceneForRegularActivity() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: nil,
            activityType: nil,
            supportsMultipleScenes: false
        )

        #expect(configuration.name == MonoclyAppDelegate.mainSceneConfigurationName)
        #expect(configuration.sceneClass === UIWindowScene.self)
        #expect(configuration.delegateClass === MonoclyMainSceneDelegate.self)
    }

    @Test
    func appDelegateKeepsInspectorSceneForRestoredInspectorSession() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
            activityType: nil,
            supportsMultipleScenes: true
        )

        #expect(configuration.name == MonoclyAppDelegate.inspectorSceneConfigurationName)
        #expect(configuration.sceneClass === UIWindowScene.self)
        #expect(configuration.delegateClass === MonoclyInspectorSceneDelegate.self)
    }

    @Test
    func appDelegateFallsBackToMainSceneWhenMultipleScenesAreUnsupported() {
        let configurations = [
            MonoclyAppDelegate.sceneConfiguration(
                for: .windowApplication,
                existingConfigurationName: nil,
                activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
                supportsMultipleScenes: false
            ),
            MonoclyAppDelegate.sceneConfiguration(
                for: .windowApplication,
                existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
                activityType: nil,
                supportsMultipleScenes: false
            )
        ]

        for configuration in configurations {
            #expect(configuration.name == MonoclyAppDelegate.mainSceneConfigurationName)
            #expect(configuration.sceneClass === UIWindowScene.self)
            #expect(configuration.delegateClass === MonoclyMainSceneDelegate.self)
        }
    }

    @Test
    func appDelegateForcesMainSceneDuringLegacyRecovery() {
        let configuration = MonoclyAppDelegate.sceneConfiguration(
            for: .windowApplication,
            existingConfigurationName: MonoclyAppDelegate.inspectorSceneConfigurationName,
            activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
            supportsMultipleScenes: true,
            forceMainSceneConfiguration: true
        )

        #expect(configuration.name == MonoclyAppDelegate.mainSceneConfigurationName)
        #expect(configuration.sceneClass === UIWindowScene.self)
        #expect(configuration.delegateClass === MonoclyMainSceneDelegate.self)
    }

    @Test
    func presentWindowFailsWithoutMultipleSceneSupport() throws {
        try withCleanState { context in
            let fixture = try makeHostedRootViewController(context: context)
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

            let didPresent = coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorSession: fixture.rootViewController.inspectorSession
            )
            #expect(didPresent == false)
            #expect(activationCount == 0)
            #expect(coordinator.hasInspectorWindowForTesting == false)
        }
    }

    @Test
    func legacySceneRecoveryLeavesConnectedMainSessionAlive() throws {
        try withCleanState { _ in
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

            #expect(destroyedSceneSessions.isEmpty)
        }
    }

    @Test
    func legacySceneRecoveryComputesStaleSessionIdentifiers() {
        let staleSessionIdentifiers = MonoclyAppDelegate.staleRecoveredSessionIdentifiers(
            openSessionIdentifiers: ["main-session", "stale-session-a", "stale-session-b"],
            connectedMainSessionIdentifier: "main-session"
        )

        #expect(staleSessionIdentifiers == ["stale-session-a", "stale-session-b"])
    }

    @Test
    func mainSceneDelegateConnectsWindowAndFinalizesRootOnDisconnect() async throws {
        try await withCleanState { context in
            let sceneDelegate = MonoclyMainSceneDelegate()
            let windowScene = try makeWindowScene()
            let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)

            sceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

            let hostWindow = try #require(sceneDelegate.window)
            context.retain(hostWindow)
            let rootViewController = try #require(sceneDelegate.rootViewController)
            #expect(hostWindow.rootViewController === rootViewController)

            sceneDelegate.sceneDidBecomeActive(windowScene)
            #expect(MonoclyWindowContextStore.shared.currentWindowScene === windowScene)
            #expect(MonoclyWindowContextStore.shared.currentWindow === hostWindow)

            sceneDelegate.disconnect(windowScene: windowScene)

            #expect(sceneDelegate.window == nil)
            #expect(sceneDelegate.rootViewController == nil)
            #expect(MonoclyWindowContextStore.shared.currentWindowScene == nil)
            #expect(MonoclyWindowContextStore.shared.currentWindow == nil)
            await rootViewController.waitForInspectorSessionTransitions()
        }
    }

    @Test
    func mainSceneDelegateDisconnectCompletesSessionTransition() async throws {
        try await withCleanState { context in
            let sceneDelegate = MonoclyMainSceneDelegate()
            let windowScene = try makeWindowScene()
            let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)

            sceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

            let hostWindow = try #require(sceneDelegate.window)
            context.retain(hostWindow)
            let rootViewController = try #require(sceneDelegate.rootViewController)

            sceneDelegate.disconnect(windowScene: windowScene)
            await rootViewController.waitForInspectorSessionTransitions()

            #expect(sceneDelegate.window == nil)
            #expect(sceneDelegate.rootViewController == nil)
        }
    }

    @Test
    func mainSceneDelegatePreservesInspectorSessionWhileInspectorSceneIsConnected() async throws {
        try await withCleanState { context in
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

            let mainWindow = try #require(mainSceneDelegate.window)
            context.retain(mainWindow)
            let rootViewController = try #require(mainSceneDelegate.rootViewController)

            #expect(coordinator.presentWindow(
                from: rootViewController,
                browserStore: rootViewController.store,
                inspectorSession: rootViewController.inspectorSession
            ))

            inspectorSceneDelegate.connect(windowScene: windowScene)

            let inspectorWindow = try #require(inspectorSceneDelegate.window)
            context.retain(inspectorWindow)

            mainSceneDelegate.disconnect(windowScene: windowScene)
            await rootViewController.waitForInspectorSessionTransitions()

            #expect(mainSceneDelegate.window == nil)
            #expect(mainSceneDelegate.rootViewController == nil)
            #expect(waitForCondition {
                BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorSession)
            })

            inspectorSceneDelegate.disconnect(windowScene: windowScene)
            await rootViewController.waitForInspectorSessionTransitions()

            #expect(waitForCondition {
                BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorSession) == false
            })
        }
    }

    @Test
    func mainSceneDelegateReusesPreservedRootWhenSceneReconnects() throws {
        try withCleanState { context in
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

            let firstWindow = try #require(mainSceneDelegate.window)
            context.retain(firstWindow)
            let firstRootViewController = try #require(mainSceneDelegate.rootViewController)

            #expect(coordinator.presentWindow(
                from: firstRootViewController,
                browserStore: firstRootViewController.store,
                inspectorSession: firstRootViewController.inspectorSession
            ))

            inspectorSceneDelegate.connect(windowScene: windowScene)
            context.retain(try #require(inspectorSceneDelegate.window))

            mainSceneDelegate.disconnect(windowScene: windowScene)
            mainSceneDelegate.connect(windowScene: windowScene, launchConfiguration: launchConfiguration)

            let reconnectedWindow = try #require(mainSceneDelegate.window)
            context.retain(reconnectedWindow)
            let reconnectedRootViewController = try #require(mainSceneDelegate.rootViewController)

            #expect(firstRootViewController === reconnectedRootViewController)
        }
    }

    @Test
    func inspectorSceneDelegateAttachesAndDetachesInspectorWindowSession() throws {
        try withCleanState { context in
            let fixture = try makeHostedRootViewController(context: context)
            let coordinator = BrowserInspectorCoordinator()
            let sceneDelegate = MonoclyInspectorSceneDelegate()

            coordinator.setSupportsMultipleScenesProviderForTesting { true }
            coordinator.setSceneActivationRequesterForTesting(
                BrowserInspectorSceneActivationRequester(
                    activateScene: { _, _, _, _ in }
                )
            )

            #expect(coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorSession: fixture.rootViewController.inspectorSession
            ))
            #expect(coordinator.hasInspectorWindowForTesting)

            sceneDelegate.connect(windowScene: fixture.windowScene)

            let inspectorWindow = try #require(sceneDelegate.window)
            context.retain(inspectorWindow)
            #expect(inspectorWindow.rootViewController === sceneDelegate.inspectorViewController)
            #expect(coordinator.hasInspectorWindowForTesting)

            sceneDelegate.scene(
                fixture.windowScene,
                continue: NSUserActivity(activityType: BrowserInspectorCoordinator.inspectorWindowSceneActivityType)
            )
            #expect(coordinator.hasInspectorWindowForTesting)

            sceneDelegate.disconnect(windowScene: fixture.windowScene)

            #expect(sceneDelegate.window == nil)
            #expect(sceneDelegate.inspectorViewController == nil)
            #expect(coordinator.hasInspectorWindowForTesting == false)
        }
    }

    @Test
    func inspectorSceneDisconnectAllowsImmediateSessionReuseWhilePending() throws {
        try withCleanState { context in
            let fixture = try makeHostedRootViewController(context: context)
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

            #expect(coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorSession: fixture.rootViewController.inspectorSession
            ))

            sceneDelegate.connect(windowScene: fixture.windowScene)
            sceneDelegate.disconnect(windowScene: fixture.windowScene)

            #expect(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session) == false)

            #expect(coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorSession: fixture.rootViewController.inspectorSession
            ))
            #expect(coordinator.hasInspectorWindowForTesting)
            #expect(activatedSceneSession === fixture.windowScene.session)
            #expect(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session))

            sceneDelegate.connect(windowScene: fixture.windowScene)
            #expect(destroyedSceneSession == nil)
            #expect(sceneDelegate.window != nil)
            #expect(coordinator.hasInspectorWindowForTesting)

            sceneDelegate.disconnect(windowScene: fixture.windowScene)
            BrowserInspectorCoordinator.handleInspectorWindowSceneSessionsDidDiscard([fixture.windowScene.session])
            #expect(BrowserInspectorCoordinator.canConnectInspectorWindowScene(fixture.windowScene.session) == false)
        }
    }

    @Test
    func inspectorSceneDelegateDestroysOrphanedRestoredSessionWithoutContext() throws {
        try withCleanState { _ in
            let windowScene = try makeWindowScene()
            let sceneDelegate = MonoclyInspectorSceneDelegate()
            var destroyedSceneSession: UISceneSession?

            MonoclyInspectorSceneDelegate.setSceneDestructionRequesterForTesting(
                BrowserInspectorSceneDestructionRequester { sceneSession in
                    destroyedSceneSession = sceneSession
                }
            )

            sceneDelegate.connect(windowScene: windowScene)

            #expect(destroyedSceneSession === windowScene.session)
            #expect(sceneDelegate.window == nil)
            #expect(sceneDelegate.inspectorViewController == nil)
        }
    }

    @Test
    func orphanedInspectorSceneActivationDoesNotPolluteWindowRegistry() throws {
        try withCleanState { context in
            let orphanWindowScene = try makeWindowScene()
            let sceneDelegate = MonoclyInspectorSceneDelegate()

            MonoclyInspectorSceneDelegate.setSceneDestructionRequesterForTesting(
                BrowserInspectorSceneDestructionRequester { _ in }
            )

            sceneDelegate.connect(windowScene: orphanWindowScene)
            sceneDelegate.sceneDidBecomeActive(orphanWindowScene)

            let fixture = try makeHostedRootViewController(context: context)
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

            #expect(coordinator.presentWindow(
                from: fixture.rootViewController,
                browserStore: fixture.rootViewController.store,
                inspectorSession: fixture.rootViewController.inspectorSession
            ))

            #expect(activatedSceneSession == nil)
        }
    }
}

@MainActor
private extension MonoclyLifecycleTests {
    @MainActor
    final class TestContext {
        private var cleanupHandlers: [@MainActor () -> Void] = []
        private var retainedWindows: [UIWindow] = []

        func retain(_ window: UIWindow) {
            retainedWindows.append(window)
        }

        func addCleanup(_ cleanup: @escaping @MainActor () -> Void) {
            cleanupHandlers.append(cleanup)
        }

        func cleanup() {
            for cleanupHandler in cleanupHandlers.reversed() {
                cleanupHandler()
            }
            cleanupHandlers.removeAll()

            BrowserInspectorCoordinator.clearInspectorWindowPresentation()
            MonoclyInspectorSceneDelegate.resetSceneDestructionRequesterForTesting()
            MonoclyWindowContextStore.shared.resetForTesting()

            for window in retainedWindows {
                window.isHidden = true
                window.rootViewController = nil
            }
            retainedWindows.removeAll()
        }
    }

    struct HostedRootFixture {
        let windowScene: UIWindowScene
        let rootViewController: BrowserRootViewController
    }

    func withCleanState<T>(_ body: (TestContext) throws -> T) rethrows -> T {
        let context = TestContext()
        defer {
            context.cleanup()
        }
        return try body(context)
    }

    func withCleanState<T>(_ body: (TestContext) async throws -> T) async rethrows -> T {
        let context = TestContext()
        defer {
            context.cleanup()
        }
        return try await body(context)
    }

    func makeHostedRootViewController(context: TestContext) throws -> HostedRootFixture {
        let windowScene = try makeWindowScene()
        let launchConfiguration = BrowserLaunchConfiguration(initialURL: URL(string: "about:blank")!)
        let rootViewController = BrowserRootViewController(launchConfiguration: launchConfiguration)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        context.retain(window)
        drainMainQueue()
        return HostedRootFixture(windowScene: windowScene, rootViewController: rootViewController)
    }

    func makeWindowScene() throws -> UIWindowScene {
        try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
    }

    func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

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
        sceneData: Data = Data("SceneState".utf8),
        context: TestContext
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

        context.addCleanup {
            try? FileManager.default.removeItem(at: rootDirectoryURL)
        }

        return savedStateDirectoryURL
    }
}
#endif

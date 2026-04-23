#if canImport(UIKit)
import UIKit

struct BrowserInspectorSceneDestructionRequester {
    let destroySceneSession: @MainActor (_ sceneSession: UISceneSession) -> Void

    static let live = BrowserInspectorSceneDestructionRequester { sceneSession in
        UIApplication.shared.requestSceneSessionDestruction(
            sceneSession,
            options: nil,
            errorHandler: nil
        )
    }
}

struct MonoclyLegacySceneRecoveryEnvironment {
    var openSessions: @MainActor () -> [UISceneSession]
    var destroySceneSession: @MainActor (_ sceneSession: UISceneSession) -> Void

    static let live = MonoclyLegacySceneRecoveryEnvironment(
        openSessions: {
            Array(UIApplication.shared.openSessions)
        },
        destroySceneSession: { sceneSession in
            UIApplication.shared.requestSceneSessionDestruction(
                sceneSession,
                options: nil,
                errorHandler: nil
            )
        }
    )
}

enum MonoclyLegacySceneStateRecovery {
    static let bundleIdentifier = "lynnpd.Monocly"
    private static let legacyMarkers = [
        Data("SwiftUI.AppSceneDelegate".utf8),
        Data("com.apple.SwiftUI.sceneID".utf8)
    ]

    static func savedStateDirectoryURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? MonoclyLegacySceneStateRecovery.bundleIdentifier,
        libraryDirectoryURL: URL? = nil
    ) -> URL? {
        let resolvedLibraryDirectoryURL = libraryDirectoryURL
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        guard let resolvedLibraryDirectoryURL else {
            return nil
        }

        return resolvedLibraryDirectoryURL
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
    }

    static func recoverIfNeeded(
        savedStateDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: savedStateDirectoryURL.path) else {
            return false
        }
        guard containsLegacySwiftUISceneState(
            savedStateDirectoryURL: savedStateDirectoryURL,
            fileManager: fileManager
        ) else {
            return false
        }

        try fileManager.removeItem(at: savedStateDirectoryURL)
        return true
    }

    static func containsLegacySwiftUISceneState(
        savedStateDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: savedStateDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                continue
            }
            if legacyMarkers.contains(where: { data.range(of: $0) != nil }) {
                return true
            }
        }

        return false
    }
}

@main
@MainActor
final class MonoclyAppDelegate: UIResponder, UIApplicationDelegate {
    static let mainSceneConfigurationName = "Monocly Main"
    static let inspectorSceneConfigurationName = "Monocly Inspector"
    private var didRecoverLegacySceneState = false
    private var legacySceneRecoveryEnvironment = MonoclyLegacySceneRecoveryEnvironment.live

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = launchOptions
        recoverLegacySceneStateIfNeeded(supportsMultipleScenes: application.supportsMultipleScenes)
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = application
        _ = launchOptions
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return Self.sceneConfiguration(
            for: connectingSceneSession.role,
            existingConfigurationName: connectingSceneSession.configuration.name,
            activityType: Self.sceneActivityType(
                connectingSceneSession: connectingSceneSession,
                options: options
            ),
            supportsMultipleScenes: application.supportsMultipleScenes,
            forceMainSceneConfiguration: didRecoverLegacySceneState && application.supportsMultipleScenes == false
        )
    }

    static func sceneConfiguration(
        for role: UISceneSession.Role,
        existingConfigurationName: String? = nil,
        activityType: String?,
        supportsMultipleScenes: Bool = UIApplication.shared.supportsMultipleScenes,
        forceMainSceneConfiguration: Bool = false
    ) -> UISceneConfiguration {
        let configurationName: String?
        let delegateClass: AnyClass?
        let shouldUseInspectorConfiguration = forceMainSceneConfiguration == false
            && supportsMultipleScenes
            && role == .windowApplication
            && (
                activityType == BrowserInspectorCoordinator.inspectorWindowSceneActivityType
                    || existingConfigurationName == inspectorSceneConfigurationName
            )

        if shouldUseInspectorConfiguration {
            configurationName = inspectorSceneConfigurationName
            delegateClass = MonoclyInspectorSceneDelegate.self
        } else {
            configurationName = mainSceneConfigurationName
            delegateClass = role == .windowApplication ? MonoclyMainSceneDelegate.self : nil
        }

        let configuration = UISceneConfiguration(name: configurationName, sessionRole: role)
        if role == .windowApplication {
            configuration.sceneClass = UIWindowScene.self
        }
        configuration.delegateClass = delegateClass
        return configuration
    }

    static func sceneActivityType(
        connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> String? {
        options.userActivities.first?.activityType
            ?? connectingSceneSession.stateRestorationActivity?.activityType
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        _ = application
        BrowserInspectorCoordinator.handleInspectorWindowSceneSessionsDidDiscard(sceneSessions)
    }

    @discardableResult
    func recoverLegacySceneStateIfNeeded(
        supportsMultipleScenes: Bool = UIApplication.shared.supportsMultipleScenes,
        fileManager: FileManager = .default,
        savedStateDirectoryURL: URL? = MonoclyLegacySceneStateRecovery.savedStateDirectoryURL()
    ) -> Bool {
        guard supportsMultipleScenes == false,
              didRecoverLegacySceneState == false,
              let savedStateDirectoryURL else {
            return false
        }

        let didRecover = (try? MonoclyLegacySceneStateRecovery.recoverIfNeeded(
            savedStateDirectoryURL: savedStateDirectoryURL,
            fileManager: fileManager
        )) ?? false
        didRecoverLegacySceneState = didRecover
        return didRecover
    }

    func setLegacySceneRecoveryEnvironmentForTesting(_ environment: MonoclyLegacySceneRecoveryEnvironment) {
        legacySceneRecoveryEnvironment = environment
    }

    func setDidRecoverLegacySceneStateForTesting(_ value: Bool) {
        didRecoverLegacySceneState = value
    }

    func handleLegacySceneRecoveryAfterMainSceneConnectedForTesting(_ windowScene: UIWindowScene) {
        handleLegacySceneRecoveryAfterMainSceneConnected(windowScene)
    }
}

extension MonoclyAppDelegate {
    static func staleRecoveredSessionIdentifiers(
        openSessionIdentifiers: [String],
        connectedMainSessionIdentifier: String
    ) -> Set<String> {
        Set(openSessionIdentifiers.filter { $0 != connectedMainSessionIdentifier })
    }
}

private extension MonoclyAppDelegate {
    func handleLegacySceneRecoveryAfterMainSceneConnected(_ windowScene: UIWindowScene) {
        guard didRecoverLegacySceneState else {
            return
        }

        let staleSessionIdentifiers = Self.staleRecoveredSessionIdentifiers(
            openSessionIdentifiers: legacySceneRecoveryEnvironment.openSessions().map(\.persistentIdentifier),
            connectedMainSessionIdentifier: windowScene.session.persistentIdentifier
        )
        legacySceneRecoveryEnvironment.openSessions()
            .filter { staleSessionIdentifiers.contains($0.persistentIdentifier) }
            .forEach { legacySceneRecoveryEnvironment.destroySceneSession($0) }
        didRecoverLegacySceneState = false
    }
}

@MainActor
final class MonoclyMainSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var rootViewController: BrowserRootViewController?
    private var closingRootTransitionTasks: [UUID: Task<Void, Never>] = [:]
    private var preservedRootViewController: BrowserRootViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        _ = session
        _ = connectionOptions
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        connect(windowScene: windowScene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        MonoclyWindowContextStore.shared.sceneDidBecomeActive(windowScene)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        MonoclyWindowContextStore.shared.sceneWillResignActive(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        disconnect(windowScene: windowScene)
    }

    func connect(
        windowScene: UIWindowScene,
        launchConfiguration: BrowserLaunchConfiguration = .current()
    ) {
        let rootViewController = preservedRootViewController
            ?? BrowserRootViewController(launchConfiguration: launchConfiguration)
        if preservedRootViewController === rootViewController {
            BrowserInspectorCoordinator.setInspectorWindowReleaseHandler(
                for: rootViewController.inspectorController,
                nil
            )
            preservedRootViewController = nil
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        self.window = window
        self.rootViewController = rootViewController
        MonoclyWindowContextStore.shared.registerConnectedScene(windowScene)
        window.makeKeyAndVisible()
        (UIApplication.shared.delegate as? MonoclyAppDelegate)?
            .handleLegacySceneRecoveryAfterMainSceneConnected(windowScene)

        if windowScene.activationState == .foregroundActive {
            MonoclyWindowContextStore.shared.sceneDidBecomeActive(windowScene)
        }
    }

    func disconnect(windowScene: UIWindowScene) {
        if let rootViewController {
            if BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorController) {
                preservedRootViewController = rootViewController
                rootViewController.prepareForSceneDisconnectionPreservingInspectorSession()
                BrowserInspectorCoordinator.setInspectorWindowReleaseHandler(
                    for: rootViewController.inspectorController
                ) { [weak self, rootViewController] in
                    if self?.preservedRootViewController === rootViewController {
                        self?.preservedRootViewController = nil
                    }
                    rootViewController.finalizeInspectorSession()
                    Task { @MainActor [rootViewController] in
                        await rootViewController.waitForInspectorSessionTransitions()
                    }
                }
            } else {
                rootViewController.finalizeInspectorSession()
                retainRootUntilInspectorSessionTransitionsFinish(rootViewController)
            }
        }
        window?.rootViewController = nil
        window?.isHidden = true
        rootViewController = nil
        window = nil
        MonoclyWindowContextStore.shared.sceneDidDisconnect(windowScene)
    }

    private func retainRootUntilInspectorSessionTransitionsFinish(_ rootViewController: BrowserRootViewController) {
        let taskID = UUID()
        closingRootTransitionTasks[taskID] = Task { @MainActor [weak self, rootViewController] in
            await rootViewController.waitForInspectorSessionTransitions()
            self?.closingRootTransitionTasks[taskID] = nil
        }
    }
}

@MainActor
final class MonoclyInspectorSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var inspectorViewController: BrowserInspectorWindowHostingController?
    private static var sceneDestructionRequester = BrowserInspectorSceneDestructionRequester.live

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        _ = session
        _ = connectionOptions
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        connect(windowScene: windowScene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene,
              inspectorViewController != nil else {
            return
        }
        BrowserInspectorCoordinator.attachInspectorWindowSceneSession(windowScene.session)
        inspectorViewController?.updateInspectorContext()
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
              let windowScene = scene as? UIWindowScene,
              inspectorViewController != nil else {
            return
        }
        BrowserInspectorCoordinator.attachInspectorWindowSceneSession(windowScene.session)
        inspectorViewController?.updateInspectorContext()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }
        disconnect(windowScene: windowScene)
    }

    func connect(windowScene: UIWindowScene) {
        // Inspector scene restoration is limited to live in-process context; orphaned
        // restored sessions are discarded instead of showing an unusable placeholder.
        guard BrowserInspectorCoordinator.canConnectInspectorWindowScene(windowScene.session) else {
            Self.sceneDestructionRequester.destroySceneSession(windowScene.session)
            return
        }

        let inspectorViewController = BrowserInspectorWindowHostingController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = inspectorViewController
        self.window = window
        self.inspectorViewController = inspectorViewController
        BrowserInspectorCoordinator.attachInspectorWindowSceneSession(windowScene.session)
        window.makeKeyAndVisible()
        inspectorViewController.updateInspectorContext()
    }

    func disconnect(windowScene: UIWindowScene) {
        BrowserInspectorCoordinator.handleInspectorWindowSceneDidDisconnect(windowScene.session)
        window?.rootViewController = nil
        window?.isHidden = true
        inspectorViewController = nil
        window = nil
    }

    static func setSceneDestructionRequesterForTesting(_ requester: BrowserInspectorSceneDestructionRequester) {
        sceneDestructionRequester = requester
    }

    static func resetSceneDestructionRequesterForTesting() {
        sceneDestructionRequester = .live
    }
}
#endif

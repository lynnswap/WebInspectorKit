#if canImport(UIKit)
import UIKit

@main
@MainActor
final class MonoclyAppDelegate: UIResponder, UIApplicationDelegate {
    static let mainSceneConfigurationName = "Monocly Main"
    static let inspectorSceneConfigurationName = "Monocly Inspector"

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        _ = application
        return Self.sceneConfiguration(
            for: connectingSceneSession.role,
            existingConfigurationName: connectingSceneSession.configuration.name,
            activityType: Self.sceneActivityType(
                connectingSceneSession: connectingSceneSession,
                options: options
            )
        )
    }

    static func sceneConfiguration(
        for role: UISceneSession.Role,
        existingConfigurationName: String? = nil,
        activityType: String?
    ) -> UISceneConfiguration {
        let configurationName: String?
        let delegateClass: AnyClass?
        let shouldUseInspectorConfiguration = role == .windowApplication
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
}

@MainActor
final class MonoclyMainSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var rootViewController: BrowserRootViewController?

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
        let rootViewController = BrowserRootViewController(launchConfiguration: launchConfiguration)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        self.window = window
        self.rootViewController = rootViewController
        MonoclyWindowContextStore.shared.registerConnectedScene(windowScene)
        window.makeKeyAndVisible()

        if windowScene.activationState == .foregroundActive {
            MonoclyWindowContextStore.shared.sceneDidBecomeActive(windowScene)
        }
    }

    func disconnect(windowScene: UIWindowScene) {
        rootViewController?.finalizeInspectorSession()
        window?.rootViewController = nil
        window?.isHidden = true
        rootViewController = nil
        window = nil
        MonoclyWindowContextStore.shared.sceneDidDisconnect(windowScene)
    }
}

@MainActor
final class MonoclyInspectorSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var inspectorViewController: BrowserInspectorWindowHostingController?

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
}
#elseif canImport(AppKit)
import AppKit

@main
@MainActor
final class MonoclyAppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindowControllerFactory: (BrowserLaunchConfiguration) -> NSWindowController
    private var hasInstalledWindowObservers = false
    private lazy var mainWindowController = mainWindowControllerFactory(.current())

    override init() {
        mainWindowControllerFactory = { launchConfiguration in
            MonoclyMainWindowController(launchConfiguration: launchConfiguration)
        }
        super.init()
    }

    init(mainWindowControllerFactory: @escaping (BrowserLaunchConfiguration) -> NSWindowController) {
        self.mainWindowControllerFactory = mainWindowControllerFactory
        super.init()
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = MonoclyAppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        installWindowObserversIfNeeded()
        NSApp.setActivationPolicy(.regular)
        showMainWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        MonoclyWindowContextStore.shared.refreshCurrentWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = sender
        _ = flag
        guard mainWindowController.window?.isVisible != true else {
            return false
        }
        showMainWindow(nil)
        return false
    }

    private func showMainWindow(_ sender: Any?) {
        mainWindowController.showWindow(sender)
        mainWindowController.window?.orderFrontRegardless()
        mainWindowController.window?.makeKeyAndOrderFront(sender)
    }

    private func installWindowObserversIfNeeded() {
        guard hasInstalledWindowObservers == false else {
            return
        }
        hasInstalledWindowObservers = true

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(handleWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        MonoclyWindowContextStore.shared.noteCurrentWindow(notification.object as? NSWindow)
    }

    @objc private func handleWindowDidBecomeMain(_ notification: Notification) {
        MonoclyWindowContextStore.shared.noteCurrentWindow(notification.object as? NSWindow)
    }

    @objc private func handleWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        MonoclyWindowContextStore.shared.handleClosingWindow(window)
    }
}

@MainActor
final class MonoclyMainWindowController: NSWindowController, NSWindowDelegate {
    private let launchConfiguration: BrowserLaunchConfiguration
    private var needsFreshRootViewController = false

    init(launchConfiguration: BrowserLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        super.init(window: nil)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        ensureWindow()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        needsFreshRootViewController = true
    }

    private func ensureWindow() {
        if let window {
            if needsFreshRootViewController,
               BrowserInspectorCoordinator.hasVisibleInspectorWindow == false {
                replaceRootViewController(in: window)
                needsFreshRootViewController = false
            }
            return
        }

        let window = NSWindow(contentViewController: makeRootViewController())
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.minSize = NSSize(width: 640, height: 480)
        window.delegate = self
        self.window = window
    }

    private func replaceRootViewController(in window: NSWindow) {
        window.toolbar = nil
        window.contentViewController = makeRootViewController()
    }

    private func makeRootViewController() -> BrowserRootViewController {
        BrowserRootViewController(launchConfiguration: launchConfiguration)
    }
}
#endif

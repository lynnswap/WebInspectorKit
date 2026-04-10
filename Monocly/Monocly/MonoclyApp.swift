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
            canRestoreExistingInspectorSession: BrowserInspectorCoordinator.canRestoreInspectorWindowScene(
                connectingSceneSession
            ),
            activityType: Self.sceneActivityType(
                connectingSceneSession: connectingSceneSession,
                options: options
            )
        )
    }

    static func sceneConfiguration(
        for role: UISceneSession.Role,
        existingConfigurationName: String? = nil,
        canRestoreExistingInspectorSession: Bool = false,
        activityType: String?
    ) -> UISceneConfiguration {
        let configurationName: String?
        let delegateClass: AnyClass?
        let shouldUseInspectorConfiguration = role == .windowApplication
            && (
                activityType == BrowserInspectorCoordinator.inspectorWindowSceneActivityType
                    || (
                        existingConfigurationName == inspectorSceneConfigurationName
                            && canRestoreExistingInspectorSession
                    )
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

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        _ = application
        BrowserInspectorCoordinator.handleInspectorWindowSceneSessionsDidDiscard(sceneSessions)
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

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == BrowserInspectorCoordinator.inspectorWindowSceneActivityType,
              let windowScene = scene as? UIWindowScene else {
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
import WebInspectorKit

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
        installMainMenu()
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

    private func installMainMenu() {
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: applicationName)

        let aboutItem = NSMenuItem(
            title: "About \(applicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide \(applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.target = NSApp
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
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
    private var retainedStore: BrowserStore?
    private var retainedInspectorController: WIInspectorController?

    init(launchConfiguration: BrowserLaunchConfiguration) {
        self.launchConfiguration = launchConfiguration
        super.init(window: nil)
        shouldCascadeWindows = false
        BrowserInspectorCoordinator.setInspectorWindowCloseHandler { [weak self] in
            self?.handleInspectorWindowDidClose()
        }
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
        guard let window = notification.object as? NSWindow else {
            return
        }
        if let rootViewController = window.contentViewController as? BrowserRootViewController {
            if BrowserInspectorCoordinator.hasVisibleInspectorWindow {
                retainedStore = rootViewController.store
                retainedInspectorController = rootViewController.inspectorController
                rootViewController.prepareForWindowClosurePreservingInspectorSession()
            } else {
                retainedStore = nil
                retainedInspectorController = nil
                rootViewController.finalizeInspectorSessionForWindowClosure()
            }
        }
        window.toolbar = nil
        window.contentViewController = nil
        needsFreshRootViewController = true
    }

    private func ensureWindow() {
        discardRetainedInspectorSessionIfNeeded()

        if let window {
            if needsFreshRootViewController || (window.contentViewController as? BrowserRootViewController) == nil {
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
        let rootViewController = BrowserRootViewController(
            store: retainedStore,
            inspectorController: retainedInspectorController,
            launchConfiguration: launchConfiguration
        )
        retainedStore = nil
        retainedInspectorController = nil
        return rootViewController
    }

    private func handleInspectorWindowDidClose() {
        guard let retainedInspectorController else {
            return
        }
        retainedStore = nil
        self.retainedInspectorController = nil
        Task { @MainActor in
            await retainedInspectorController.finalize()
        }
    }

    private func discardRetainedInspectorSessionIfNeeded() {
        guard retainedInspectorController != nil,
              BrowserInspectorCoordinator.hasVisibleInspectorWindow == false else {
            return
        }
        retainedStore = nil
        retainedInspectorController = nil
    }
}
#endif

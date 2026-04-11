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

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        _ = application
        BrowserInspectorCoordinator.handleInspectorWindowSceneSessionsDidDiscard(sceneSessions)
    }
}

@MainActor
final class MonoclyMainSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var rootViewController: BrowserRootViewController?
    private var closingRootTransitionTasks: [UUID: Task<Void, Never>] = [:]

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
        if let rootViewController {
            if BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorController) {
                rootViewController.prepareForSceneDisconnectionPreservingInspectorSession()
                BrowserInspectorCoordinator.setInspectorWindowReleaseHandler(
                    for: rootViewController.inspectorController
                ) { [rootViewController] in
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
#elseif canImport(AppKit)
import AppKit
import WebInspectorKit

@main
@MainActor
final class MonoclyAppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindowControllerFactory: (BrowserLaunchConfiguration) -> NSWindowController
    private var hasInstalledWindowObservers = false
    private var additionalWindowControllers: [NSWindowController] = []
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
        guard hasVisibleBrowserWindow == false else {
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

    private func showNewMainWindow(_ sender: Any?) {
        let windowController = mainWindowControllerFactory(.current())
        installRetainedInspectorSessionCleanup(for: windowController)
        additionalWindowControllers.append(windowController)
        windowController.showWindow(sender)
        windowController.window?.orderFrontRegardless()
        windowController.window?.makeKeyAndOrderFront(sender)
    }

    private var hasVisibleBrowserWindow: Bool {
        mainWindowController.window?.isVisible == true
            || additionalWindowControllers.contains { $0.window?.isVisible == true }
    }

    private func installRetainedInspectorSessionCleanup(for windowController: NSWindowController) {
        guard let mainWindowController = windowController as? MonoclyMainWindowController else {
            return
        }
        mainWindowController.onRetainedInspectorSessionDidEnd = { [weak self, weak mainWindowController] in
            guard let self, let mainWindowController else {
                return
            }
            self.additionalWindowControllers.removeAll { $0 === mainWindowController }
        }
    }

    private func installMainMenu() {
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem(title: applicationName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: applicationName)
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")

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

        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(handleNewWindowMenuItem(_:)),
            keyEquivalent: "n"
        )
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.target = nil
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.target = nil
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.target = nil
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        minimizeItem.target = nil
        windowMenu.addItem(minimizeItem)

        let zoomItem = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        zoomItem.target = nil
        windowMenu.addItem(zoomItem)
        windowMenu.addItem(.separator())

        let bringAllToFrontItem = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAllToFrontItem.target = NSApp
        windowMenu.addItem(bringAllToFrontItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleNewWindowMenuItem(_ sender: Any?) {
        showNewMainWindow(sender)
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
        additionalWindowControllers.removeAll { windowController in
            guard windowController.window === window else {
                return false
            }
            guard let mainWindowController = windowController as? MonoclyMainWindowController else {
                return true
            }
            return mainWindowController.isRetainingInspectorSessionAfterWindowClosure == false
        }
    }

    var additionalWindowControllerCountForTesting: Int {
        additionalWindowControllers.count
    }
}

@MainActor
final class MonoclyMainWindowController: NSWindowController, NSWindowDelegate {
    private let launchConfiguration: BrowserLaunchConfiguration
    private var needsFreshRootViewController = false
    private var retainedRootViewController: BrowserRootViewController?
    private var closingRootTransitionTasks: [UUID: Task<Void, Never>] = [:]
    var onRetainedInspectorSessionDidEnd: (() -> Void)?

    var isRetainingInspectorSessionAfterWindowClosure: Bool {
        if retainedRootViewController != nil {
            return true
        }
        guard let rootViewController = window?.contentViewController as? BrowserRootViewController else {
            return false
        }
        return BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorController)
    }

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
        guard let window = notification.object as? NSWindow else {
            return
        }
        if let rootViewController = window.contentViewController as? BrowserRootViewController {
            if BrowserInspectorCoordinator.hasInspectorWindow(for: rootViewController.inspectorController) {
                retainedRootViewController = rootViewController
                rootViewController.prepareForWindowClosurePreservingInspectorSession()
            } else {
                retainedRootViewController = nil
                clearInspectorWindowReleaseHandler(for: rootViewController)
                rootViewController.finalizeInspectorSessionForWindowClosure()
                retainRootUntilInspectorSessionTransitionsFinish(rootViewController)
            }
        }
        window.toolbar = nil
        window.contentViewController = nil
        needsFreshRootViewController = true
    }

    private func ensureWindow() {
        if let window {
            if needsFreshRootViewController || (window.contentViewController as? BrowserRootViewController) == nil {
                if let retainedRootViewController {
                    window.toolbar = nil
                    window.contentViewController = retainedRootViewController
                    self.retainedRootViewController = nil
                } else {
                    replaceRootViewController(in: window)
                }
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
        if let rootViewController = window.contentViewController as? BrowserRootViewController {
            clearInspectorWindowReleaseHandler(for: rootViewController)
        }
        window.contentViewController = makeRootViewController()
    }

    private func makeRootViewController() -> BrowserRootViewController {
        let rootViewController = BrowserRootViewController(launchConfiguration: launchConfiguration)
        BrowserInspectorCoordinator.setInspectorWindowReleaseHandler(
            for: rootViewController.inspectorController
        ) { [weak self, weak rootViewController] in
            guard let rootViewController else {
                return
            }
            self?.handleInspectorWindowDidRelease(rootViewController: rootViewController)
        }
        return rootViewController
    }

    private func clearInspectorWindowReleaseHandler(for rootViewController: BrowserRootViewController) {
        BrowserInspectorCoordinator.setInspectorWindowReleaseHandler(
            for: rootViewController.inspectorController,
            nil
        )
    }

    private func handleInspectorWindowDidRelease(rootViewController: BrowserRootViewController) {
        guard retainedRootViewController === rootViewController else {
            return
        }
        self.retainedRootViewController = nil
        clearInspectorWindowReleaseHandler(for: rootViewController)
        rootViewController.finalizeInspectorSessionForWindowClosure()
        retainRootUntilInspectorSessionTransitionsFinish(rootViewController)
        onRetainedInspectorSessionDidEnd?()
    }

    private func retainRootUntilInspectorSessionTransitionsFinish(_ rootViewController: BrowserRootViewController) {
        let taskID = UUID()
        closingRootTransitionTasks[taskID] = Task { [weak self, rootViewController] in
            await rootViewController.waitForInspectorSessionTransitions()
            guard let self else {
                return
            }
            if self.retainedRootViewController === rootViewController {
                self.retainedRootViewController = nil
            }
            self.closingRootTransitionTasks[taskID] = nil
        }
    }
}
#endif

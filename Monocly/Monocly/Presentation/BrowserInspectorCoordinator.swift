import Foundation
import WebInspectorKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
struct BrowserInspectorWindowContext {
    static let sceneActivityType = "lynnpd.webspector.web-inspector"

    let browserStore: BrowserStore
    let inspectorController: WIInspectorController
    let tabs: [WITab]
}

struct BrowserInspectorSceneActivationRequester {
    let activateScene: @MainActor (
        _ sceneSession: UISceneSession?,
        _ userActivity: NSUserActivity,
        _ requestingScene: UIScene?,
        _ errorHandler: @escaping (Error) -> Void
    ) -> Void

    static let live = BrowserInspectorSceneActivationRequester { sceneSession, userActivity, requestingScene, errorHandler in
        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = requestingScene
        UIApplication.shared.requestSceneSessionActivation(
            sceneSession,
            userActivity: userActivity,
            options: options,
            errorHandler: errorHandler
        )
    }
}
#endif

@MainActor
final class BrowserInspectorCoordinator {
#if canImport(UIKit)
    private final class InspectorSheetObserver: NSObject, UIAdaptivePresentationControllerDelegate {
        var onDismiss: (() -> Void)?

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss?()
        }
    }

    private final class InspectorWindowRegistry {
        private final class WeakSceneSessionBox {
            weak var session: UISceneSession?

            init(session: UISceneSession) {
                self.session = session
            }
        }

        private var context: BrowserInspectorWindowContext?
        private var sceneSessionsByIdentifier: [String: WeakSceneSessionBox] = [:]
        private var restorableSceneSessionIdentifiers: Set<String> = []
        private var isPendingPresentation = false
        private var observers: [UUID: (Bool) -> Void] = [:]

        var currentContext: BrowserInspectorWindowContext? {
            context
        }

        var currentSceneSessions: [UISceneSession] {
            pruneDisconnectedSceneSessions()
            return sceneSessionsByIdentifier.values.compactMap(\.session)
        }

        var presentationState: Bool {
            pruneDisconnectedSceneSessions()
            return Self.isPresentationActive(
                hasContext: context != nil,
                isPendingPresentation: isPendingPresentation,
                attachedSceneCount: sceneSessionsByIdentifier.count
            )
        }

        func setContext(_ context: BrowserInspectorWindowContext?) {
            self.context = context
        }

        func beginPendingPresentation() {
            let previousState = presentationState
            isPendingPresentation = true
            notifyObserversIfNeeded(previousState: previousState)
        }

        func attachSceneSession(_ sceneSession: UISceneSession) {
            let previousState = presentationState
            let persistentIdentifier = sceneSession.persistentIdentifier
            sceneSessionsByIdentifier[persistentIdentifier] = WeakSceneSessionBox(session: sceneSession)
            restorableSceneSessionIdentifiers.insert(persistentIdentifier)
            isPendingPresentation = false
            notifyObserversIfNeeded(previousState: previousState)
        }

        func sceneDidDisconnect(_ sceneSession: UISceneSession) {
            let previousState = presentationState
            sceneSessionsByIdentifier.removeValue(forKey: sceneSession.persistentIdentifier)
            pruneDisconnectedSceneSessions()
            if sceneSessionsByIdentifier.isEmpty, isPendingPresentation == false {
                context = nil
            }
            notifyObserversIfNeeded(previousState: previousState)
        }

        func discardSceneSessions(_ sceneSessions: some Sequence<UISceneSession>) {
            let previousState = presentationState
            for sceneSession in sceneSessions {
                let persistentIdentifier = sceneSession.persistentIdentifier
                sceneSessionsByIdentifier.removeValue(forKey: persistentIdentifier)
                restorableSceneSessionIdentifiers.remove(persistentIdentifier)
            }
            pruneDisconnectedSceneSessions()
            if restorableSceneSessionIdentifiers.isEmpty, isPendingPresentation == false {
                context = nil
            }
            notifyObserversIfNeeded(previousState: previousState)
        }

        func canRestoreSceneSession(_ sceneSession: UISceneSession) -> Bool {
            context != nil && restorableSceneSessionIdentifiers.contains(sceneSession.persistentIdentifier)
        }

        func canConnectSceneSession(_ sceneSession: UISceneSession) -> Bool {
            context != nil
                && (
                    isPendingPresentation
                        || restorableSceneSessionIdentifiers.contains(sceneSession.persistentIdentifier)
                )
        }

        func clear() {
            let previousState = presentationState
            context = nil
            sceneSessionsByIdentifier.removeAll()
            restorableSceneSessionIdentifiers.removeAll()
            isPendingPresentation = false
            notifyObserversIfNeeded(previousState: previousState)
        }

        func addObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
            let observerID = UUID()
            observers[observerID] = observer
            observer(presentationState)
            return observerID
        }

        func removeObserver(_ observerID: UUID) {
            observers[observerID] = nil
        }

        private func pruneDisconnectedSceneSessions() {
            sceneSessionsByIdentifier = sceneSessionsByIdentifier.filter { $0.value.session != nil }
        }

        static func isPresentationActive(
            hasContext: Bool,
            isPendingPresentation: Bool,
            attachedSceneCount: Int
        ) -> Bool {
            hasContext && (isPendingPresentation || attachedSceneCount > 0)
        }

        private func notifyObserversIfNeeded(previousState: Bool) {
            let currentState = presentationState
            guard currentState != previousState else {
                return
            }
            observers.values.forEach { $0(currentState) }
        }
    }

    private static let inspectorWindowRegistry = InspectorWindowRegistry()

    private weak var presentedSheetController: WITabViewController?
    private let sheetObserver = InspectorSheetObserver()
    private var sceneActivationRequester = BrowserInspectorSceneActivationRequester.live

    var onPresentationStateChange: (() -> Void)?

    func presentSheet(
        from presenter: UIViewController,
        browserStore: BrowserStore,
        inspectorController: WIInspectorController,
        tabs: [WITab] = [.dom(), .network()]
    ) -> Bool {
        guard isPresentingInspector(presenter: presenter) == false else {
            return false
        }

        let anchor = resolvePresentationAnchor(from: presenter)
        let container = WITabViewController(
            inspectorController,
            webView: browserStore.webView,
            tabs: tabs
        )
        container.modalPresentationStyle = .pageSheet
        applyDefaultDetents(to: container)
        presentedSheetController = container
        sheetObserver.onDismiss = { [weak self, weak container] in
            guard let self else {
                return
            }
            if self.presentedSheetController === container {
                self.presentedSheetController = nil
                self.notifyPresentationStateChanged()
            }
        }
        anchor.present(container, animated: true)
        container.presentationController?.delegate = sheetObserver
        notifyPresentationStateChanged()
        return true
    }

    func presentWindow(
        from presenter: UIViewController,
        browserStore: BrowserStore,
        inspectorController: WIInspectorController,
        tabs: [WITab] = [.dom(), .network()]
    ) -> Bool {
        guard isPresentingInspector(presenter: presenter) == false else {
            return false
        }

        Self.inspectorWindowRegistry.setContext(
            BrowserInspectorWindowContext(
                browserStore: browserStore,
                inspectorController: inspectorController,
                tabs: tabs
            )
        )
        let userActivity = Self.makeInspectorWindowUserActivity()
        let requestingScene = presenter.view.window?.windowScene ?? MonoclyWindowContextStore.shared.currentWindowScene

        let targetSceneSession = Self.inspectorWindowRegistry.currentSceneSessions.first
        if targetSceneSession == nil {
            Self.inspectorWindowRegistry.beginPendingPresentation()
        }

        sceneActivationRequester.activateScene(targetSceneSession, userActivity, requestingScene) { [weak self] _ in
            Self.inspectorWindowRegistry.clear()
            self?.notifyPresentationStateChanged()
        }

        notifyPresentationStateChanged()
        return true
    }

    func dismissInspectorWindow() {
        let sceneSessions = Self.inspectorWindowRegistry.currentSceneSessions
        if sceneSessions.isEmpty == false {
            for sceneSession in sceneSessions {
                UIApplication.shared.requestSceneSessionDestruction(sceneSession, options: nil, errorHandler: nil)
            }
            return
        }

        Self.inspectorWindowRegistry.clear()
        notifyPresentationStateChanged()
    }

    func isPresentingInspector(presenter: UIViewController? = nil) -> Bool {
        reconcilePresentationState(from: presenter)
        if presentedSheetController != nil {
            return true
        }
        return Self.inspectorWindowRegistry.presentationState
    }

    func invalidate() {
        sheetObserver.onDismiss = nil
        presentedSheetController = nil
    }

    func setSceneActivationRequesterForTesting(_ requester: BrowserInspectorSceneActivationRequester) {
        sceneActivationRequester = requester
    }

    var hasInspectorWindowForTesting: Bool {
        Self.inspectorWindowRegistry.presentationState
    }

    static var inspectorWindowSceneActivityType: String {
        BrowserInspectorWindowContext.sceneActivityType
    }

    static func inspectorWindowContext() -> BrowserInspectorWindowContext? {
        inspectorWindowRegistry.currentContext
    }

    static func attachInspectorWindowSceneSession(_ sceneSession: UISceneSession) {
        inspectorWindowRegistry.attachSceneSession(sceneSession)
    }

    static func handleInspectorWindowSceneDidDisconnect(_ sceneSession: UISceneSession) {
        inspectorWindowRegistry.sceneDidDisconnect(sceneSession)
    }

    static func handleInspectorWindowSceneSessionsDidDiscard(_ sceneSessions: Set<UISceneSession>) {
        inspectorWindowRegistry.discardSceneSessions(sceneSessions)
    }

    static func canRestoreInspectorWindowScene(_ sceneSession: UISceneSession) -> Bool {
        inspectorWindowRegistry.canRestoreSceneSession(sceneSession)
    }

    static func canConnectInspectorWindowScene(_ sceneSession: UISceneSession) -> Bool {
        inspectorWindowRegistry.canConnectSceneSession(sceneSession)
    }

    static func observeInspectorWindowPresentation(_ observer: @escaping (Bool) -> Void) -> UUID {
        inspectorWindowRegistry.addObserver(observer)
    }

    static func removeInspectorWindowObservation(_ observerID: UUID) {
        inspectorWindowRegistry.removeObserver(observerID)
    }

    static func clearInspectorWindowPresentation() {
        inspectorWindowRegistry.clear()
    }

    static func inspectorWindowPresentationStateForTesting(
        hasContext: Bool,
        isPendingPresentation: Bool,
        attachedSceneCount: Int
    ) -> Bool {
        InspectorWindowRegistry.isPresentationActive(
            hasContext: hasContext,
            isPendingPresentation: isPendingPresentation,
            attachedSceneCount: attachedSceneCount
        )
    }

    private static func makeInspectorWindowUserActivity() -> NSUserActivity {
        let userActivity = NSUserActivity(activityType: BrowserInspectorWindowContext.sceneActivityType)
        userActivity.targetContentIdentifier = BrowserInspectorWindowContext.sceneActivityType
        return userActivity
    }

    private func resolvePresentationAnchor(from presenter: UIViewController) -> UIViewController {
        let baseController = presenter.view.window?.rootViewController ?? presenter.navigationController ?? presenter
        return topViewController(from: baseController) ?? presenter
    }

    private func applyDefaultDetents(to controller: UIViewController) {
        guard let sheet = controller.sheetPresentationController else {
            return
        }
        sheet.detents = [.medium(), .large()]
        sheet.selectedDetentIdentifier = .medium
        sheet.prefersGrabberVisible = false
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        sheet.largestUndimmedDetentIdentifier = .large
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        guard let root else {
            return nil
        }
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let split = root as? UISplitViewController {
            return topViewController(from: split.viewControllers.last)
        }
        return root
    }

    private func notifyPresentationStateChanged() {
        onPresentationStateChange?()
    }

    private func reconcilePresentationState(from presenter: UIViewController?) {
        guard let presentedSheetController else {
            return
        }
        if presentedSheetController.presentingViewController != nil {
            return
        }
        guard isPresentedViewControllerInChain(presentedSheetController, from: presenter) == false else {
            return
        }
        self.presentedSheetController = nil
    }

    private func isPresentedViewControllerInChain(
        _ target: UIViewController,
        from presenter: UIViewController?
    ) -> Bool {
        var cursor = presenter?.presentedViewController
        while let current = cursor {
            if current === target {
                return true
            }
            cursor = current.presentedViewController
        }
        return false
    }
#elseif canImport(AppKit)
    private final class InspectorWindowStore {
        weak var window: NSWindow?
        private var currentInspectorControllerID: ObjectIdentifier?
        private var releaseHandlersByInspectorControllerID: [ObjectIdentifier: () -> Void] = [:]
        private var closeObserver: NSObjectProtocol?

        deinit {
            removeCloseObserver()
        }

        func setWindow(_ window: NSWindow?, inspectorController: WIInspectorController) {
            removeCloseObserver()
            self.window = window
            currentInspectorControllerID = ObjectIdentifier(inspectorController)

            guard let window else {
                currentInspectorControllerID = nil
                return
            }

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                let releaseHandler = self?.currentInspectorControllerID.flatMap {
                    self?.releaseHandlersByInspectorControllerID[$0]
                }
                self?.window = nil
                self?.currentInspectorControllerID = nil
                self?.removeCloseObserver()
                releaseHandler?()
            }
        }

        func setCurrentInspectorController(_ inspectorController: WIInspectorController) {
            let previousInspectorControllerID = currentInspectorControllerID
            let nextInspectorControllerID = ObjectIdentifier(inspectorController)
            currentInspectorControllerID = nextInspectorControllerID
            if let previousInspectorControllerID,
               previousInspectorControllerID != nextInspectorControllerID {
                releaseHandlersByInspectorControllerID[previousInspectorControllerID]?()
            }
        }

        func hasWindow(for inspectorController: WIInspectorController) -> Bool {
            window != nil && currentInspectorControllerID == ObjectIdentifier(inspectorController)
        }

        func setReleaseHandler(
            for inspectorController: WIInspectorController,
            _ handler: (() -> Void)?
        ) {
            let inspectorControllerID = ObjectIdentifier(inspectorController)
            releaseHandlersByInspectorControllerID[inspectorControllerID] = handler
        }

        private func removeCloseObserver() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
        }
    }

    private static let inspectorWindowStore = InspectorWindowStore()

    static func hasInspectorWindow(for inspectorController: WIInspectorController) -> Bool {
        inspectorWindowStore.hasWindow(for: inspectorController)
    }

    static func setInspectorWindowReleaseHandler(
        for inspectorController: WIInspectorController,
        _ handler: (() -> Void)?
    ) {
        inspectorWindowStore.setReleaseHandler(for: inspectorController, handler)
    }

    static func present(
        from parentWindow: NSWindow?,
        browserStore: BrowserStore,
        inspectorController: WIInspectorController,
        tabs: [WITab] = [.dom(), .network()]
    ) -> Bool {
        let resolvedParentWindow = parentWindow ?? MonoclyWindowContextStore.shared.currentWindow

        if let existingWindow = Self.inspectorWindowStore.window,
           let existingContainer = existingWindow.contentViewController as? WITabViewController {
            existingContainer.setTabs(tabs)
            existingContainer.setPageWebView(browserStore.webView)
            existingContainer.setInspectorController(inspectorController)
            Self.inspectorWindowStore.setCurrentInspectorController(inspectorController)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        let container = WITabViewController(
            inspectorController,
            webView: browserStore.webView,
            tabs: tabs
        )
        let window = NSWindow(contentViewController: container)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Web Inspector"
        window.setContentSize(NSSize(width: 960, height: 720))
        window.minSize = NSSize(width: 640, height: 480)

        if let resolvedParentWindow {
            let parentFrame = resolvedParentWindow.frame
            let origin = NSPoint(
                x: parentFrame.midX - (window.frame.width / 2),
                y: parentFrame.midY - (window.frame.height / 2)
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        Self.inspectorWindowStore.setWindow(window, inspectorController: inspectorController)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
#endif
}

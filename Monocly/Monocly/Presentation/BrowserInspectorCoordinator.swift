import Foundation
import WebInspectorKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
struct BrowserInspectorWindowContext {
    static let sceneActivityType = "lynnpd.webspector.web-inspector"

    let browserStore: BrowserStore
    let inspectorController: WIInspectorController
    let tabs: [V2_WITab]
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
        private var reusableSceneSession: WeakSceneSessionBox?
        private var reusableSceneSessionIdentifier: String?
        private var restorableSceneSessionIdentifiers: Set<String> = []
        private var staleSceneSessionIdentifiers: Set<String> = []
        private var isPendingPresentation = false
        private var observers: [UUID: (Bool) -> Void] = [:]
        private var releaseHandlersByInspectorControllerID: [ObjectIdentifier: () -> Void] = [:]

        var currentContext: BrowserInspectorWindowContext? {
            context
        }

        var currentSceneSessions: [UISceneSession] {
            pruneDisconnectedSceneSessions()
            return sceneSessionsByIdentifier.values.compactMap(\.session)
        }

        var preferredActivationSceneSession: UISceneSession? {
            pruneDisconnectedSceneSessions()
            return sceneSessionsByIdentifier.values.compactMap(\.session).first
                ?? reusableSceneSession?.session
        }

        var hasAttachedSceneSession: Bool {
            pruneDisconnectedSceneSessions()
            return sceneSessionsByIdentifier.isEmpty == false
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
            let previousInspectorControllerID = self.context.map { ObjectIdentifier($0.inspectorController) }
            let nextInspectorControllerID = context.map { ObjectIdentifier($0.inspectorController) }
            self.context = context
            if previousInspectorControllerID != nextInspectorControllerID {
                releaseContext(for: previousInspectorControllerID)
            }
        }

        func beginPendingPresentation() {
            let previousState = presentationState
            staleSceneSessionIdentifiers.formUnion(restorableSceneSessionIdentifiers)
            restorableSceneSessionIdentifiers.removeAll()
            isPendingPresentation = true
            notifyObserversIfNeeded(previousState: previousState)
        }

        func attachSceneSession(_ sceneSession: UISceneSession) {
            let previousState = presentationState
            let persistentIdentifier = sceneSession.persistentIdentifier
            sceneSessionsByIdentifier[persistentIdentifier] = WeakSceneSessionBox(session: sceneSession)
            if reusableSceneSessionIdentifier == persistentIdentifier {
                reusableSceneSession = nil
                reusableSceneSessionIdentifier = nil
            }
            staleSceneSessionIdentifiers.remove(persistentIdentifier)
            restorableSceneSessionIdentifiers.insert(persistentIdentifier)
            isPendingPresentation = false
            notifyObserversIfNeeded(previousState: previousState)
        }

        func sceneDidDisconnect(_ sceneSession: UISceneSession) {
            let previousState = presentationState
            let persistentIdentifier = sceneSession.persistentIdentifier
            sceneSessionsByIdentifier.removeValue(forKey: persistentIdentifier)
            reusableSceneSession = WeakSceneSessionBox(session: sceneSession)
            reusableSceneSessionIdentifier = persistentIdentifier
            restorableSceneSessionIdentifiers.remove(persistentIdentifier)
            staleSceneSessionIdentifiers.insert(persistentIdentifier)
            pruneDisconnectedSceneSessions()
            if restorableSceneSessionIdentifiers.isEmpty, isPendingPresentation == false {
                setContext(nil)
            }
            notifyObserversIfNeeded(previousState: previousState)
        }

        func discardSceneSessions(_ sceneSessions: some Sequence<UISceneSession>) {
            let previousState = presentationState
            for sceneSession in sceneSessions {
                let persistentIdentifier = sceneSession.persistentIdentifier
                sceneSessionsByIdentifier.removeValue(forKey: persistentIdentifier)
                if reusableSceneSessionIdentifier == persistentIdentifier {
                    reusableSceneSession = nil
                    reusableSceneSessionIdentifier = nil
                }
                restorableSceneSessionIdentifiers.remove(persistentIdentifier)
                staleSceneSessionIdentifiers.remove(persistentIdentifier)
            }
            pruneDisconnectedSceneSessions()
            if restorableSceneSessionIdentifiers.isEmpty,
               sceneSessionsByIdentifier.isEmpty,
               isPendingPresentation == false {
                setContext(nil)
            }
            notifyObserversIfNeeded(previousState: previousState)
        }

        func hasWindow(for inspectorController: WIInspectorController) -> Bool {
            context?.inspectorController === inspectorController && presentationState
        }

        func setReleaseHandler(
            for inspectorController: WIInspectorController,
            _ handler: (() -> Void)?
        ) {
            let inspectorControllerID = ObjectIdentifier(inspectorController)
            releaseHandlersByInspectorControllerID[inspectorControllerID] = handler
        }

        func canRestoreSceneSession(_ sceneSession: UISceneSession) -> Bool {
            context != nil
                && staleSceneSessionIdentifiers.contains(sceneSession.persistentIdentifier) == false
                && restorableSceneSessionIdentifiers.contains(sceneSession.persistentIdentifier)
        }

        func canConnectSceneSession(_ sceneSession: UISceneSession) -> Bool {
            let persistentIdentifier = sceneSession.persistentIdentifier
            return context != nil
                && (
                    isPendingPresentation
                        || (
                            staleSceneSessionIdentifiers.contains(persistentIdentifier) == false
                                && restorableSceneSessionIdentifiers.contains(persistentIdentifier)
                        )
                )
        }

        func clear() {
            let previousState = presentationState
            let previousInspectorControllerID = context.map { ObjectIdentifier($0.inspectorController) }
            setContext(nil)
            sceneSessionsByIdentifier.removeAll()
            reusableSceneSession = nil
            reusableSceneSessionIdentifier = nil
            restorableSceneSessionIdentifiers.removeAll()
            staleSceneSessionIdentifiers.removeAll()
            isPendingPresentation = false
            releaseContext(for: previousInspectorControllerID)
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
            if reusableSceneSession?.session == nil {
                reusableSceneSession = nil
                reusableSceneSessionIdentifier = nil
            }
        }

        private func releaseContext(for inspectorControllerID: ObjectIdentifier?) {
            guard let inspectorControllerID,
                  let releaseHandler = releaseHandlersByInspectorControllerID.removeValue(forKey: inspectorControllerID) else {
                return
            }
            releaseHandler()
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

    private weak var presentedSheetController: UIViewController?
    private let sheetObserver = InspectorSheetObserver()
    private var sceneActivationRequester = BrowserInspectorSceneActivationRequester.live
    private var supportsMultipleScenesProvider: @MainActor () -> Bool = { UIApplication.shared.supportsMultipleScenes }

    var onPresentationStateChange: (() -> Void)?

    func presentSheet(
        from presenter: UIViewController,
        browserStore: BrowserStore,
        inspectorController: WIInspectorController,
        tabs: [V2_WITab] = V2_WITab.defaults,
        launchConfiguration: BrowserLaunchConfiguration? = nil
    ) -> Bool {
        guard isPresentingInspector(presenter: presenter) == false else {
            return false
        }

        let anchor = resolvePresentationAnchor(from: presenter)
        let configuration = launchConfiguration ?? BrowserLaunchConfiguration(
            initialURL: browserStore.currentURL ?? URL(string: "about:blank")!
        )

        let sheetController: UIViewController
        if let launchConfiguration, launchConfiguration.uiTestScenario != nil {
            sheetController = BrowserInspectorSheetHostingController(
                browserStore: browserStore,
                inspectorController: inspectorController,
                launchConfiguration: configuration,
                tabs: tabs
            )
        } else {
            let viewController = V2_WIViewController(tabs: tabs)
            viewController.attachToMonoclyBrowser(browserStore)
            sheetController = viewController
        }
        sheetController.modalPresentationStyle = .pageSheet
        applyDefaultDetents(to: sheetController)
        presentedSheetController = sheetController
        sheetObserver.onDismiss = { [weak self, weak sheetController] in
            guard let self else {
                return
            }
            if self.presentedSheetController === sheetController {
                (sheetController as? V2_WIViewController)?.detachFromMonoclyBrowser()
                self.presentedSheetController = nil
                self.notifyPresentationStateChanged()
            }
        }
        anchor.present(sheetController, animated: true)
        sheetController.presentationController?.delegate = sheetObserver
        notifyPresentationStateChanged()
        return true
    }

    func presentWindow(
        from presenter: UIViewController,
        browserStore: BrowserStore,
        inspectorController: WIInspectorController,
        tabs: [V2_WITab] = V2_WITab.defaults
    ) -> Bool {
        guard isPresentingInspector(presenter: presenter) == false else {
            return false
        }
        guard supportsMultipleScenesProvider() else {
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

        let targetSceneSession = Self.inspectorWindowRegistry.preferredActivationSceneSession
        if Self.inspectorWindowRegistry.hasAttachedSceneSession == false {
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
        (presentedSheetController as? V2_WIViewController)?.detachFromMonoclyBrowser()
        presentedSheetController = nil
    }

    func setSceneActivationRequesterForTesting(_ requester: BrowserInspectorSceneActivationRequester) {
        sceneActivationRequester = requester
    }

    func setSupportsMultipleScenesProviderForTesting(_ provider: @escaping @MainActor () -> Bool) {
        supportsMultipleScenesProvider = provider
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

    static func hasInspectorWindow(for inspectorController: WIInspectorController) -> Bool {
        inspectorWindowRegistry.hasWindow(for: inspectorController)
    }

    static func setInspectorWindowReleaseHandler(
        for inspectorController: WIInspectorController,
        _ handler: (() -> Void)?
    ) {
        inspectorWindowRegistry.setReleaseHandler(for: inspectorController, handler)
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
        sheet.largestUndimmedDetentIdentifier = .medium
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
        (presentedSheetController as? V2_WIViewController)?.detachFromMonoclyBrowser()
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
#endif
}

#if canImport(UIKit)
extension V2_WIViewController {
    func attachToMonoclyBrowser(_ browserStore: BrowserStore) {
        let webView = browserStore.webView
        Task { @MainActor [weak self, webView] in
            await self?.attach(to: webView)
        }
    }

    func detachFromMonoclyBrowser() {
        Task { @MainActor [self] in
            await detach()
        }
    }
}
#endif

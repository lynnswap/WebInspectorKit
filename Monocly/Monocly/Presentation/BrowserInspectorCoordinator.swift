import Foundation
import Observation
import ObservationBridge
import WebInspectorKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
extension BrowserInspectorCoordinator {
    struct WindowContext {
        static let sceneActivityType = "lynnpd.webspector.web-inspector"

        let browserStore: BrowserWindowStore
        let inspectorSession: WebInspectorSession
    }
}

extension BrowserInspectorCoordinator {
    struct SceneActivationRequester {
        let activateScene: @MainActor (
            _ sceneSession: UISceneSession?,
            _ userActivity: NSUserActivity,
            _ requestingScene: UIScene?,
            _ errorHandler: @escaping (Error) -> Void
        ) -> Void

        static let live = BrowserInspectorCoordinator.SceneActivationRequester { sceneSession, userActivity, requestingScene, errorHandler in
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
}
#endif

@MainActor
@Observable
final class BrowserInspectorPresentationState {
    private(set) var isPresenting = false

    func update(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }
}

@MainActor
final class BrowserInspectorCoordinator {
#if canImport(UIKit)
    private final class InspectorSheetObserver: NSObject, UIAdaptivePresentationControllerDelegate {
        var onDismiss: (() -> Void)?

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss?()
        }
    }

    private static let inspectorWindowRegistry = BrowserInspectorWindowRegistry()

    private weak var presentedSheetController: UIViewController?
    private let sheetObserver = InspectorSheetObserver()
    private var sheetUserInterfaceStyleObservation: PortableObservationTracking.Token?
    private var sceneActivationRequester = BrowserInspectorCoordinator.SceneActivationRequester.live
    private var supportsMultipleScenesProvider: @MainActor () -> Bool = { UIApplication.shared.supportsMultipleScenes }

    let presentationState = BrowserInspectorPresentationState()

    func presentSheet(
        from presenter: UIViewController,
        inspectorSession: WebInspectorSession
    ) -> Bool {
        guard isPresentingInspector(presenter: presenter) == false else {
            return false
        }

        let anchor = resolvePresentationAnchor(from: presenter)
        let sheetController = WebInspectorViewController(session: inspectorSession)
        sheetController.automaticallyDetachesOnDismiss = false
        if #available(iOS 26.0, *) {
            sheetController.drawsBackground = false
        }
        sheetController.modalPresentationStyle = .pageSheet
        applyDefaultDetents(to: sheetController)
        bindSheetUserInterfaceStyle(to: sheetController, inspectorSession: inspectorSession)
        presentedSheetController = sheetController
        sheetObserver.onDismiss = { [weak self, weak sheetController] in
            guard let self else {
                return
            }
            if self.presentedSheetController === sheetController {
                self.presentedSheetController = nil
                self.cancelSheetUserInterfaceStyleObservation()
                self.syncPresentationStateWithLifecycle()
            }
        }
        anchor.present(sheetController, animated: true)
        sheetController.presentationController?.delegate = sheetObserver
        syncPresentationStateWithLifecycle()
        return true
    }

    func presentWindow(
        from presenter: UIViewController,
        browserStore: BrowserWindowStore,
        inspectorSession: WebInspectorSession
    ) -> Bool {
        guard isPresentingInspector(presenter: presenter) == false else {
            return false
        }
        guard supportsMultipleScenesProvider() else {
            return false
        }

        Self.inspectorWindowRegistry.setContext(
            BrowserInspectorCoordinator.WindowContext(
                browserStore: browserStore,
                inspectorSession: inspectorSession
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
            self?.syncPresentationStateWithLifecycle()
        }

        syncPresentationStateWithLifecycle()
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
        syncPresentationStateWithLifecycle()
    }

    func isPresentingInspector(presenter: UIViewController? = nil) -> Bool {
        reconcilePresentationState(from: presenter)
        updatePresentationState()
        return presentationState.isPresenting
    }

    func refreshPresentationState(presenter: UIViewController? = nil) {
        reconcilePresentationState(from: presenter)
        updatePresentationState()
    }

    func invalidate() {
        sheetObserver.onDismiss = nil
        presentedSheetController = nil
        cancelSheetUserInterfaceStyleObservation()
    }

    func setSceneActivationRequesterForTesting(_ requester: BrowserInspectorCoordinator.SceneActivationRequester) {
        sceneActivationRequester = requester
    }

    func setSupportsMultipleScenesProviderForTesting(_ provider: @escaping @MainActor () -> Bool) {
        supportsMultipleScenesProvider = provider
    }

    var hasInspectorWindowForTesting: Bool {
        Self.inspectorWindowRegistry.presentationState
    }

    var presentedSheetControllerForTesting: UIViewController? {
        presentedSheetController
    }

    static var inspectorWindowSceneActivityType: String {
        BrowserInspectorCoordinator.WindowContext.sceneActivityType
    }

    static func inspectorWindowContext() -> BrowserInspectorCoordinator.WindowContext? {
        inspectorWindowRegistry.currentContext
    }

    static func hasInspectorWindow(for inspectorSession: WebInspectorSession) -> Bool {
        inspectorWindowRegistry.hasWindow(for: inspectorSession)
    }

    static func setInspectorWindowReleaseHandler(
        for inspectorSession: WebInspectorSession,
        _ handler: (() -> Void)?
    ) {
        inspectorWindowRegistry.setReleaseHandler(for: inspectorSession, handler)
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

    private static func makeInspectorWindowUserActivity() -> NSUserActivity {
        let userActivity = NSUserActivity(activityType: BrowserInspectorCoordinator.WindowContext.sceneActivityType)
        userActivity.targetContentIdentifier = BrowserInspectorCoordinator.WindowContext.sceneActivityType
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

    private func bindSheetUserInterfaceStyle(
        to sheetController: UIViewController,
        inspectorSession: WebInspectorSession
    ) {
        cancelSheetUserInterfaceStyleObservation()
        sheetUserInterfaceStyleObservation = withPortableContinuousObservation { [weak self, weak sheetController, weak inspectorSession] _ in
            guard let sheet = sheetController?.sheetPresentationController else {
                return
            }
            guard let inspectorSession else {
                return
            }
            self?.applySheetUserInterfaceStyle(inspectorSession.pageUserInterfaceStyle, to: sheet)
        }
    }

    private func cancelSheetUserInterfaceStyleObservation() {
        sheetUserInterfaceStyleObservation?.cancel()
        sheetUserInterfaceStyleObservation = nil
    }

    private func applySheetUserInterfaceStyle(
        _ style: UIUserInterfaceStyle,
        to sheet: UISheetPresentationController
    ) {
        sheet.traitOverrides.userInterfaceStyle = style
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

    private func syncPresentationStateWithLifecycle() {
        updatePresentationState()
    }

    private func updatePresentationState() {
        presentationState.update(
            isPresenting: presentedSheetController != nil || Self.inspectorWindowRegistry.presentationState
        )
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
        cancelSheetUserInterfaceStyleObservation()
        syncPresentationStateWithLifecycle()
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

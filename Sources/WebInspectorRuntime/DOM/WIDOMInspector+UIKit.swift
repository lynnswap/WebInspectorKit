#if canImport(UIKit)
import OSLog
import UIKit

private let domWindowActivationLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMWindowActivation")

@MainActor
package protocol WIDOMUIKitSceneActivationTarget: AnyObject {
    var activationState: UIScene.ActivationState { get }
    var sceneSession: UISceneSession? { get }
}

extension UIWindowScene: WIDOMUIKitSceneActivationTarget {
    package var sceneSession: UISceneSession? {
        session
    }
}

@MainActor
package protocol WIDOMUIKitSceneActivationRequesting {
    func requestActivation(
        of target: any WIDOMUIKitSceneActivationTarget,
        requestingScene: UIScene?,
        errorHandler: ((any Error) -> Void)?
    )
}

extension UIApplication: WIDOMUIKitSceneActivationRequesting {
    package func requestActivation(
        of target: any WIDOMUIKitSceneActivationTarget,
        requestingScene: UIScene?,
        errorHandler: ((any Error) -> Void)?
    ) {
        guard let sceneSession = target.sceneSession else {
            return
        }

        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = requestingScene

        requestSceneSessionActivation(
            sceneSession,
            userActivity: nil,
            options: options,
            errorHandler: errorHandler
        )
    }
}

@MainActor
package enum WIDOMUIKitSceneActivationEnvironment {
    package static var requester: any WIDOMUIKitSceneActivationRequesting = UIApplication.shared
    package static var sceneProvider: @MainActor (UIWindow) -> (any WIDOMUIKitSceneActivationTarget)? = { $0.windowScene }
    package static var requestingSceneProvider: @MainActor (any WIDOMUIKitSceneActivationTarget) -> UIScene? = { _ in nil }
}

extension WIDOMInspector {
    func disablePageScrollingForSelection() {
        guard let pageWebView else {
            return
        }
        let scrollView = pageWebView.scrollView
        scrollBackup = (
            isScrollEnabled: scrollView.isScrollEnabled,
            isPanEnabled: scrollView.panGestureRecognizer.isEnabled
        )
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    func restorePageScrollingState() {
        guard let pageWebView, let scrollBackup else {
            self.scrollBackup = nil
            return
        }
        pageWebView.scrollView.isScrollEnabled = scrollBackup.isScrollEnabled
        pageWebView.scrollView.panGestureRecognizer.isEnabled = scrollBackup.isPanEnabled
        self.scrollBackup = nil
    }

    func activatePageWindowForSelectionIfPossible() {
        guard let pageWindow = pageWebView?.window else {
            return
        }

        pageWindow.makeKey()

        guard let pageScene = WIDOMUIKitSceneActivationEnvironment.sceneProvider(pageWindow) else {
            return
        }
        guard pageScene.activationState != .foregroundActive else {
            return
        }

        let requestingScene = sceneActivationRequestingScene
            ?? WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider(pageScene)
        WIDOMUIKitSceneActivationEnvironment.requester.requestActivation(
            of: pageScene,
            requestingScene: requestingScene
        ) { error in
            domWindowActivationLogger.error("page scene activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func waitForPageWindowActivationIfNeeded() async {
        guard let pageWindow = pageWebView?.window else {
            return
        }
        guard let pageScene = WIDOMUIKitSceneActivationEnvironment.sceneProvider(pageWindow) else {
            return
        }
        guard pageScene.activationState != .foregroundActive else {
            return
        }

        for _ in 0..<40 {
            if pageScene.activationState == .foregroundActive {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
#endif

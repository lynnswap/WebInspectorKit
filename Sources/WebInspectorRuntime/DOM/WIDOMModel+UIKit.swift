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
        errorHandler: ((any Error) -> Void)?
    )
}

extension UIApplication: WIDOMUIKitSceneActivationRequesting {
    package func requestActivation(
        of target: any WIDOMUIKitSceneActivationTarget,
        errorHandler: ((any Error) -> Void)?
    ) {
        guard let sceneSession = target.sceneSession else {
            return
        }

        requestSceneSessionActivation(
            sceneSession,
            userActivity: nil,
            options: nil,
            errorHandler: errorHandler
        )
    }
}

@MainActor
package enum WIDOMUIKitSceneActivationEnvironment {
    package static var requester: any WIDOMUIKitSceneActivationRequesting = UIApplication.shared
    package static var sceneProvider: @MainActor (UIWindow) -> (any WIDOMUIKitSceneActivationTarget)? = { $0.windowScene }
}

extension WIDOMModel {
    func activatePageWindowForSelectionIfPossible() {
        guard let pageWindow = session.pageWebView?.window else {
            return
        }

        pageWindow.makeKey()

        guard let pageScene = WIDOMUIKitSceneActivationEnvironment.sceneProvider(pageWindow) else {
            return
        }
        guard pageScene.activationState != .foregroundActive else {
            return
        }

        WIDOMUIKitSceneActivationEnvironment.requester.requestActivation(of: pageScene) { error in
            domWindowActivationLogger.error("page scene activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func waitForPageWindowActivationIfNeeded() async {
        guard let pageWindow = session.pageWebView?.window else {
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

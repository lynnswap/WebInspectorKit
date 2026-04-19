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

    func setNativeInspectorNodeSearchEnabled(_ enabled: Bool) {
        if usesCustomSelectionHitTestOverlay {
            if enabled {
                installSelectionHitTestOverlay()
            } else {
                removeSelectionHitTestOverlay()
            }
            return
        }

        removeSelectionHitTestOverlay()

        guard let pageWebView,
              let contentView = findWKContentView(in: pageWebView)
        else {
            return
        }

        let selector = NSSelectorFromString(enabled ? "_enableInspectorNodeSearch" : "_disableInspectorNodeSearch")
        guard contentView.responds(to: selector) else {
            return
        }
        _ = unsafe contentView.perform(selector)
    }

    private func installSelectionHitTestOverlay() {
        guard let pageWebView else {
            return
        }

        if selectionHitTestOverlay?.superview === pageWebView {
            selectionHitTestOverlay?.frame = pageWebView.bounds
            return
        }

        removeSelectionHitTestOverlay()
        let overlay = WIDOMSelectionHitTestOverlay(inspector: self)
        overlay.frame = pageWebView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageWebView.addSubview(overlay)
        selectionHitTestOverlay = overlay
    }

    private func removeSelectionHitTestOverlay() {
        selectionHitTestOverlay?.removeFromSuperview()
        selectionHitTestOverlay = nil
    }

    private func findWKContentView(in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)).contains("WKContentView") {
            return view
        }

        for subview in view.subviews {
            if let contentView = findWKContentView(in: subview) {
                return contentView
            }
        }

        return nil
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

    private var usesCustomSelectionHitTestOverlay: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }
}

private final class WIDOMSelectionHitTestOverlay: UIView {
    private weak var inspector: WIDOMInspector?

    init(inspector: WIDOMInspector) {
        self.inspector = inspector
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let inspector else {
            return
        }
        let point = recognizer.location(in: self)
        Task { @MainActor in
            await inspector.handlePointerInspectSelection(at: point)
        }
    }
}
#endif

#if canImport(UIKit)
import OSLog
import ObjectiveC.runtime
import UIKit
import WebKit

private let domWindowActivationLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMWindowActivation")

private enum WIDOMUIKitPrivateRuntimeObfuscation {
    static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }
}

private enum WIDOMUIKitPrivateRuntimeNames {
    // WKContentView
    static let contentViewClassName = WIDOMUIKitPrivateRuntimeObfuscation.deobfuscate(["tentView", "WKCon"])
    // WKInspectorNodeSearchGestureRecognizer
    static let inspectorNodeSearchGestureRecognizerClassName = WIDOMUIKitPrivateRuntimeObfuscation.deobfuscate(["Recognizer", "Gesture", "Search", "Node", "Inspector", "WK"])
    // _inspector
    static let webViewInspectorSelectorName = WIDOMUIKitPrivateRuntimeObfuscation.deobfuscate(["inspector", "_"])
    // isElementSelectionActive
    static let inspectorElementSelectionActiveSelectorName = WIDOMUIKitPrivateRuntimeObfuscation.deobfuscate(["Active", "Selection", "Element", "is"])
    // _inspectorNodeSearchEnabled
    static let inspectorNodeSearchEnabledIvarName = WIDOMUIKitPrivateRuntimeObfuscation.deobfuscate(["Enabled", "Search", "Node", "inspector", "_"])
    // _disableInspectorNodeSearch
    static let disableInspectorNodeSearchSelectorName = WIDOMUIKitPrivateRuntimeObfuscation.deobfuscate(["Search", "Node", "Inspector", "disable", "_"])
}

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
    func setNativeInspectorNodeSearchEnabled(_ enabled: Bool) {
        guard usesCustomSelectionHitTestOverlay else {
            return
        }
        if enabled {
            installSelectionHitTestOverlay()
        } else {
            removeSelectionHitTestOverlay()
        }
    }

    private func installSelectionHitTestOverlay() {
#if DEBUG
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
#endif
    }

    private func removeSelectionHitTestOverlay() {
#if DEBUG
        selectionHitTestOverlay?.removeFromSuperview()
        selectionHitTestOverlay = nil
#endif
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
            await Task.yield()
        }
    }

    func finishNativeInspectorNodeSearchTeardownIfNeeded() async {
        guard usesCustomSelectionHitTestOverlay == false else {
            removeSelectionHitTestOverlay()
            return
        }

        guard let pageWebView,
              let contentView = findWKContentView(in: pageWebView) else {
            return
        }

        disableNativeInspectorNodeSearch(on: contentView)

        for _ in 0..<120 {
            let nativeSelectionActive = isNativeInspectorElementSelectionActive(on: pageWebView)
            let contentViewActive = nativeInspectorNodeSearchIsActive(in: contentView)
            if nativeSelectionActive != true && contentViewActive == false {
                return
            }
            await Task.yield()
        }

        domWindowActivationLogger.error("native inspector node search teardown did not settle")
    }

    var usesCustomSelectionHitTestOverlay: Bool {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
#else
        false
#endif
    }

    private func findWKContentView(in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)).contains(WIDOMUIKitPrivateRuntimeNames.contentViewClassName) {
            return view
        }
        for subview in view.subviews {
            if let contentView = findWKContentView(in: subview) {
                return contentView
            }
        }
        return nil
    }

    private func hasNativeInspectorNodeSearchRecognizer(in contentView: UIView) -> Bool {
        contentView.gestureRecognizers?.contains {
            NSStringFromClass(type(of: $0)).contains(WIDOMUIKitPrivateRuntimeNames.inspectorNodeSearchGestureRecognizerClassName)
        } ?? false
    }

    private func nativeInspectorNodeSearchIsActive(in contentView: UIView) -> Bool {
        hasNativeInspectorNodeSearchRecognizer(in: contentView)
            || isNativeInspectorNodeSearchEnabled(in: contentView)
    }

    private func isNativeInspectorElementSelectionActive(on webView: WKWebView) -> Bool? {
        let inspectorSelector = NSSelectorFromString(WIDOMUIKitPrivateRuntimeNames.webViewInspectorSelectorName)
        guard webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() else {
            return nil
        }

        let activeSelector = NSSelectorFromString(WIDOMUIKitPrivateRuntimeNames.inspectorElementSelectionActiveSelectorName)
        guard (inspector as AnyObject).responds(to: activeSelector),
              let value = (inspector as AnyObject).value(forKey: WIDOMUIKitPrivateRuntimeNames.inspectorElementSelectionActiveSelectorName) as? NSNumber else {
            return nil
        }

        return value.boolValue
    }

    private func isNativeInspectorNodeSearchEnabled(in contentView: UIView) -> Bool {
        guard let ivar = unsafe class_getInstanceVariable(type(of: contentView), WIDOMUIKitPrivateRuntimeNames.inspectorNodeSearchEnabledIvarName) else {
            return false
        }

        let offset = unsafe ivar_getOffset(ivar)
        let base = unsafe Unmanaged.passUnretained(contentView).toOpaque()
        let rawValue = unsafe base.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee
        return rawValue != 0
    }

    private func disableNativeInspectorNodeSearch(on contentView: UIView) {
        let selector = NSSelectorFromString(WIDOMUIKitPrivateRuntimeNames.disableInspectorNodeSearchSelectorName)
        guard contentView.responds(to: selector) else {
            return
        }
        _ = unsafe contentView.perform(selector)
    }

    func nativeInspectorInteractionStateSummaryForDiagnostics() -> String? {
        guard let pageWebView else {
            return nil
        }

        let selectionActive = isNativeInspectorElementSelectionActive(on: pageWebView)
        let contentViewActive = findWKContentView(in: pageWebView).map(nativeInspectorNodeSearchIsActive(in:))

        let selectionValue = selectionActive.map { $0 ? "1" : "0" } ?? "n/a"
        let contentViewValue = contentViewActive.map { $0 ? "1" : "0" } ?? "n/a"
        return "nativeSelectionActive=\(selectionValue) contentViewActive=\(contentViewValue)"
    }
}

#if DEBUG
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
#endif

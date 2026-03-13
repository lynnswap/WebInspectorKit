#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
final class BrowserViewportStateCoordinator: NSObject {
    weak var hostView: UIView?
    weak var webView: WKWebView?
    var onInputMetricsChanged: (() -> Void)?

    private var keyboardFrameInScreen: CGRect = .null
    private var lastAppliedViewportMetrics: BrowserViewportMetrics?

    init(hostView: UIView, webView: WKWebView) {
        self.hostView = hostView
        self.webView = webView
        super.init()
        observeKeyboardNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func makeViewportState(
        safeAreaInsets: UIEdgeInsets,
        topChromeHeight: CGFloat,
        bottomChromeHeight: CGFloat,
        bottomChromeMode: BrowserBottomChromeMode
    ) -> BrowserViewportState {
        BrowserViewportState(
            safeAreaInsets: safeAreaInsets,
            topObscuredHeight: topChromeHeight,
            bottomObscuredHeight: bottomChromeHeight,
            keyboardOverlapHeight: keyboardOverlapHeight(),
            inputAccessoryOverlapHeight: inputAccessoryOverlapHeight(),
            bottomChromeMode: bottomChromeMode
        )
    }

    func applyViewportState(_ state: BrowserViewportState) {
        guard let webView else {
            return
        }

        let screenScale = hostView?.window?.screen.scale ?? hostView?.traitCollection.displayScale ?? 1
        let metrics = BrowserViewportMetrics(state: state, screenScale: screenScale)
        guard metrics != lastAppliedViewportMetrics else {
            return
        }

        lastAppliedViewportMetrics = metrics
        webView.obscuredContentInsets = metrics.obscuredInsets
        webView.wi_setPrivateUnobscuredSafeAreaInsetsIfAvailable(metrics.unobscuredSafeAreaInsets)
        webView.wi_setPrivateObscuredSafeAreaEdgesIfAvailable(metrics.safeAreaAffectedEdges)
    }

    func keyboardOverlapHeight() -> CGFloat {
        guard let hostView, let window = hostView.window, keyboardFrameInScreen.isNull == false else {
            return 0
        }

        let keyboardFrameInWindow = window.convert(keyboardFrameInScreen, from: window.screen.coordinateSpace)
        let keyboardFrameInHostView = hostView.convert(keyboardFrameInWindow, from: nil)
        return max(0, hostView.bounds.intersection(keyboardFrameInHostView).height)
    }

    private func inputAccessoryOverlapHeight() -> CGFloat {
        guard let hostView, let window = hostView.window, let inputViewBoundsInWindow = webView?.wi_inputViewBoundsInWindow else {
            return 0
        }

        let inputViewBoundsInHostView = hostView.convert(inputViewBoundsInWindow, from: window)
        return max(0, hostView.bounds.intersection(inputViewBoundsInHostView).height)
    }

    private func observeKeyboardNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleKeyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(handleKeyboardDidChangeFrame(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(handleKeyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc
    private func handleKeyboardWillChangeFrame(_ notification: Notification) {
        handleKeyboardNotification(notification, resetFrame: false)
    }

    @objc
    private func handleKeyboardDidChangeFrame(_ notification: Notification) {
        handleKeyboardNotification(notification, resetFrame: false)
    }

    @objc
    private func handleKeyboardWillHide(_ notification: Notification) {
        handleKeyboardNotification(notification, resetFrame: true)
    }

    private func handleKeyboardNotification(_ notification: Notification, resetFrame: Bool) {
        guard let endFrameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }

        keyboardFrameInScreen = endFrameValue.cgRectValue
        if resetFrame {
            keyboardFrameInScreen = .null
        }
        onInputMetricsChanged?()
    }
}

struct BrowserViewportMetrics: Equatable {
    let safeAreaInsets: UIEdgeInsets
    let obscuredInsets: UIEdgeInsets
    let unobscuredSafeAreaInsets: UIEdgeInsets
    let safeAreaAffectedEdges: UIRectEdge

    init(state: BrowserViewportState, screenScale: CGFloat) {
        safeAreaInsets = state.safeAreaInsets.wi_roundedToPixel(screenScale)
        obscuredInsets = state.finalObscuredInsets.wi_roundedToPixel(screenScale)
        unobscuredSafeAreaInsets = UIEdgeInsets(
            top: max(0, safeAreaInsets.top - obscuredInsets.top),
            left: max(0, safeAreaInsets.left - obscuredInsets.left),
            bottom: max(0, safeAreaInsets.bottom - obscuredInsets.bottom),
            right: max(0, safeAreaInsets.right - obscuredInsets.right)
        )
        safeAreaAffectedEdges = state.safeAreaAffectedEdges
    }
}

private extension UIEdgeInsets {
    func wi_roundedToPixel(_ screenScale: CGFloat) -> UIEdgeInsets {
        guard screenScale > 0 else {
            return self
        }

        func roundToPixel(_ value: CGFloat) -> CGFloat {
            (value * screenScale).rounded() / screenScale
        }

        return UIEdgeInsets(
            top: roundToPixel(top),
            left: roundToPixel(left),
            bottom: roundToPixel(bottom),
            right: roundToPixel(right)
        )
    }
}

private extension WKWebView {
    func wi_setPrivateUnobscuredSafeAreaInsetsIfAvailable(_ insets: UIEdgeInsets) {
        let selector = NSSelectorFromString("_setUnobscuredSafeAreaInsets:")
        guard responds(to: selector) else {
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, UIEdgeInsets) -> Void
        let implementation = unsafeBitCast(method(for: selector), to: Setter.self)
        implementation(self, selector, insets)
    }

    func wi_setPrivateObscuredSafeAreaEdgesIfAvailable(_ edges: UIRectEdge) {
        let selector = NSSelectorFromString("_setObscuredInsetEdgesAffectedBySafeArea:")
        guard responds(to: selector) else {
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        let implementation = unsafeBitCast(method(for: selector), to: Setter.self)
        implementation(self, selector, edges.rawValue)
    }

    var wi_inputViewBoundsInWindow: CGRect? {
        let selector = NSSelectorFromString("_inputViewBoundsInWindow")
        guard responds(to: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
        let implementation = unsafeBitCast(method(for: selector), to: Getter.self)
        return implementation(self, selector)
    }
}
#endif

#if canImport(UIKit)
import UIKit
import WebKit

public enum WIWebViewBottomChromeMode: Equatable {
    case normal
    case hiddenForKeyboard
}

public enum WIWebViewScrollEdgeEffectStyle: Equatable {
    case automatic
    case hard
    case soft
}

public struct WIWebViewChromeConfiguration: Equatable {
    public var contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior
    public var topEdgeEffectHidden: Bool
    public var bottomEdgeEffectHidden: Bool
    public var topEdgeEffectStyle: WIWebViewScrollEdgeEffectStyle
    public var bottomEdgeEffectStyle: WIWebViewScrollEdgeEffectStyle
    public var safeAreaAffectedEdges: UIRectEdge

    public init(
        contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior = .always,
        topEdgeEffectHidden: Bool = false,
        bottomEdgeEffectHidden: Bool = false,
        topEdgeEffectStyle: WIWebViewScrollEdgeEffectStyle = .soft,
        bottomEdgeEffectStyle: WIWebViewScrollEdgeEffectStyle = .soft,
        safeAreaAffectedEdges: UIRectEdge = [.top, .bottom]
    ) {
        self.contentInsetAdjustmentBehavior = contentInsetAdjustmentBehavior
        self.topEdgeEffectHidden = topEdgeEffectHidden
        self.bottomEdgeEffectHidden = bottomEdgeEffectHidden
        self.topEdgeEffectStyle = topEdgeEffectStyle
        self.bottomEdgeEffectStyle = bottomEdgeEffectStyle
        self.safeAreaAffectedEdges = safeAreaAffectedEdges
    }
}

public struct WIWebViewChromeMetrics: Equatable {
    public var safeAreaInsets: UIEdgeInsets
    public var topObscuredHeight: CGFloat
    public var bottomObscuredHeight: CGFloat
    public var keyboardOverlapHeight: CGFloat
    public var inputAccessoryOverlapHeight: CGFloat
    public var bottomChromeMode: WIWebViewBottomChromeMode
    public var safeAreaAffectedEdges: UIRectEdge

    public init(
        safeAreaInsets: UIEdgeInsets,
        topObscuredHeight: CGFloat,
        bottomObscuredHeight: CGFloat,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat,
        bottomChromeMode: WIWebViewBottomChromeMode,
        safeAreaAffectedEdges: UIRectEdge = [.top, .bottom]
    ) {
        self.safeAreaInsets = safeAreaInsets
        self.topObscuredHeight = topObscuredHeight
        self.bottomObscuredHeight = bottomObscuredHeight
        self.keyboardOverlapHeight = keyboardOverlapHeight
        self.inputAccessoryOverlapHeight = inputAccessoryOverlapHeight
        self.bottomChromeMode = bottomChromeMode
        self.safeAreaAffectedEdges = safeAreaAffectedEdges
    }

    public var finalObscuredInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: max(0, topObscuredHeight),
            left: 0,
            bottom: resolvedBottomObscuredHeight,
            right: 0
        )
    }

    private var resolvedBottomObscuredHeight: CGFloat {
        let overlayHeight = bottomChromeMode == .normal ? bottomObscuredHeight : 0
        return max(0, overlayHeight, keyboardOverlapHeight, inputAccessoryOverlapHeight)
    }
}

public struct WIWebViewChromeResolvedMetrics: Equatable {
    public let safeAreaInsets: UIEdgeInsets
    public let obscuredInsets: UIEdgeInsets
    public let unobscuredSafeAreaInsets: UIEdgeInsets
    public let safeAreaAffectedEdges: UIRectEdge

    public init(state: WIWebViewChromeMetrics, screenScale: CGFloat) {
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

@MainActor
public protocol WIWebViewChromeMetricsProviding {
    func makeChromeMetrics(
        in hostViewController: UIViewController,
        webView: WKWebView,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat
    ) -> WIWebViewChromeMetrics
}

@MainActor
public final class WIWebViewViewportCoordinator: NSObject {
    public weak var hostViewController: UIViewController?
    public weak var webView: WKWebView?
    public var configuration: WIWebViewChromeConfiguration
    public var metricsProvider: any WIWebViewChromeMetricsProviding

    private var keyboardFrameInScreen: CGRect = .null
    private var lastAppliedResolvedMetrics: WIWebViewChromeResolvedMetrics?

    var resolvedMetricsForTesting: WIWebViewChromeResolvedMetrics? {
        lastAppliedResolvedMetrics
    }

    public init(
        hostViewController: UIViewController,
        webView: WKWebView,
        configuration: WIWebViewChromeConfiguration = .init(),
        metricsProvider: any WIWebViewChromeMetricsProviding = WINavigationControllerChromeMetricsProvider()
    ) {
        self.hostViewController = hostViewController
        self.webView = webView
        self.configuration = configuration
        self.metricsProvider = metricsProvider
        super.init()
        observeKeyboardNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func handleViewDidAppear() {
        updateChromeState()
    }

    public func updateChromeState() {
        guard let hostViewController, let webView else {
            return
        }

        applyScrollViewConfiguration(to: webView.scrollView)
        hostViewController.setContentScrollView(webView.scrollView)

        let metrics = metricsProvider.makeChromeMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: keyboardOverlapHeight(),
            inputAccessoryOverlapHeight: inputAccessoryOverlapHeight()
        )
        var effectiveMetrics = metrics
        effectiveMetrics.safeAreaAffectedEdges = configuration.safeAreaAffectedEdges

        let screenScale = hostViewController.view.window?.screen.scale
            ?? hostViewController.view.traitCollection.displayScale
        let resolvedMetrics = WIWebViewChromeResolvedMetrics(
            state: effectiveMetrics,
            screenScale: screenScale
        )
        guard resolvedMetrics != lastAppliedResolvedMetrics else {
            return
        }

        lastAppliedResolvedMetrics = resolvedMetrics
        if #available(iOS 26.0, *) {
            webView.obscuredContentInsets = resolvedMetrics.obscuredInsets
        }
        WIWebViewViewportSPIBridge.apply(
            unobscuredSafeAreaInsets: resolvedMetrics.unobscuredSafeAreaInsets,
            to: webView
        )
        WIWebViewViewportSPIBridge.apply(
            obscuredSafeAreaEdges: resolvedMetrics.safeAreaAffectedEdges,
            to: webView
        )
    }

    public func invalidate() {
        NotificationCenter.default.removeObserver(self)

        guard let hostViewController, let webView else {
            return
        }

        if hostViewController.contentScrollView(for: .top) === webView.scrollView
            || hostViewController.contentScrollView(for: .bottom) === webView.scrollView {
            hostViewController.setContentScrollView(nil)
        }
    }

    private func applyScrollViewConfiguration(to scrollView: UIScrollView) {
        if scrollView.contentInsetAdjustmentBehavior != configuration.contentInsetAdjustmentBehavior {
            scrollView.contentInsetAdjustmentBehavior = configuration.contentInsetAdjustmentBehavior
        }

        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = configuration.topEdgeEffectHidden
            scrollView.topEdgeEffect.style = configuration.topEdgeEffectStyle.uiKitStyle
            scrollView.bottomEdgeEffect.isHidden = configuration.bottomEdgeEffectHidden
            scrollView.bottomEdgeEffect.style = configuration.bottomEdgeEffectStyle.uiKitStyle
        }
    }

    private func keyboardOverlapHeight() -> CGFloat {
        guard
            let hostView = hostViewController?.view,
            let window = hostView.window,
            keyboardFrameInScreen.isNull == false
        else {
            return 0
        }

        let keyboardFrameInWindow = window.convert(
            keyboardFrameInScreen,
            from: window.screen.coordinateSpace
        )
        let keyboardFrameInHostView = hostView.convert(keyboardFrameInWindow, from: nil)
        return max(0, hostView.bounds.intersection(keyboardFrameInHostView).height)
    }

    private func inputAccessoryOverlapHeight() -> CGFloat {
        guard
            let hostView = hostViewController?.view,
            let window = hostView.window,
            let webView,
            let inputViewBoundsInWindow = WIWebViewViewportSPIBridge.inputViewBoundsInWindow(of: webView)
        else {
            return 0
        }

        let inputViewBoundsInHostView = hostView.convert(inputViewBoundsInWindow, from: window)
        return max(0, hostView.bounds.intersection(inputViewBoundsInHostView).height)
    }

    private func observeKeyboardNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardDidChangeFrame(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
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
        updateChromeState()
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

@MainActor
@available(iOS 26.0, *)
private extension WIWebViewScrollEdgeEffectStyle {
    var uiKitStyle: UIScrollEdgeEffect.Style {
        switch self {
        case .automatic:
            .automatic
        case .hard:
            .hard
        case .soft:
            .soft
        }
    }
}
#endif

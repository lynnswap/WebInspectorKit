#if canImport(UIKit)
import Combine
import UIKit
import WebKit

public enum BottomChromeMode: Equatable {
    case normal
    case hiddenForKeyboard
}

public enum ScrollEdgeEffectStyle: Equatable {
    case automatic
    case hard
    case soft
}

public struct ViewportConfiguration: Equatable {
    public var contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior
    public var topEdgeEffectHidden: Bool
    public var bottomEdgeEffectHidden: Bool
    public var topEdgeEffectStyle: ScrollEdgeEffectStyle
    public var bottomEdgeEffectStyle: ScrollEdgeEffectStyle
    public var safeAreaAffectedEdges: UIRectEdge

    public init(
        contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior = .always,
        topEdgeEffectHidden: Bool = false,
        bottomEdgeEffectHidden: Bool = false,
        topEdgeEffectStyle: ScrollEdgeEffectStyle = .soft,
        bottomEdgeEffectStyle: ScrollEdgeEffectStyle = .soft,
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

public struct ViewportMetrics: Equatable {
    public var safeAreaInsets: UIEdgeInsets
    public var topObscuredHeight: CGFloat
    public var bottomObscuredHeight: CGFloat
    public var keyboardOverlapHeight: CGFloat
    public var inputAccessoryOverlapHeight: CGFloat
    public var bottomChromeMode: BottomChromeMode
    public var safeAreaAffectedEdges: UIRectEdge

    public init(
        safeAreaInsets: UIEdgeInsets,
        topObscuredHeight: CGFloat,
        bottomObscuredHeight: CGFloat,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat,
        bottomChromeMode: BottomChromeMode,
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

struct ResolvedViewportMetrics: Equatable {
    let safeAreaInsets: UIEdgeInsets
    let obscuredInsets: UIEdgeInsets
    let unobscuredSafeAreaInsets: UIEdgeInsets
    let safeAreaAffectedEdges: UIRectEdge

    init(state: ViewportMetrics, screenScale: CGFloat) {
        safeAreaInsets = state.safeAreaInsets.wk_roundedToPixel(screenScale)
        obscuredInsets = state.finalObscuredInsets.wk_roundedToPixel(screenScale)
        unobscuredSafeAreaInsets = UIEdgeInsets(
            top: max(0, safeAreaInsets.top - obscuredInsets.top),
            left: max(0, safeAreaInsets.left - obscuredInsets.left),
            bottom: max(0, safeAreaInsets.bottom - obscuredInsets.bottom),
            right: max(0, safeAreaInsets.right - obscuredInsets.right)
        )
        safeAreaAffectedEdges = state.safeAreaAffectedEdges
    }

    var contentScrollInsetFallback: UIEdgeInsets {
        UIEdgeInsets(
            top: max(0, obscuredInsets.top - safeAreaInsets.top),
            left: max(0, obscuredInsets.left - safeAreaInsets.left),
            bottom: max(0, obscuredInsets.bottom - safeAreaInsets.bottom),
            right: max(0, obscuredInsets.right - safeAreaInsets.right)
        )
    }
}

@MainActor
public protocol ViewportMetricsProvider {
    func makeViewportMetrics(
        in hostViewController: UIViewController,
        webView: WKWebView,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat
    ) -> ViewportMetrics
}

@MainActor
public final class NavigationControllerViewportMetricsProvider: ViewportMetricsProvider {
    public init() {}

    public func makeViewportMetrics(
        in hostViewController: UIViewController,
        webView: WKWebView,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat
    ) -> ViewportMetrics {
        let safeAreaInsets = hostViewController.viewIfLoaded?.safeAreaInsets ?? .zero
        return ViewportMetrics(
            safeAreaInsets: safeAreaInsets,
            topObscuredHeight: safeAreaInsets.top,
            bottomObscuredHeight: safeAreaInsets.bottom,
            keyboardOverlapHeight: keyboardOverlapHeight,
            inputAccessoryOverlapHeight: inputAccessoryOverlapHeight,
            bottomChromeMode: .normal
        )
    }
}

@MainActor
public final class ViewportCoordinator: NSObject {
    public weak var hostViewController: UIViewController? {
        didSet {
            lastAppliedResolvedMetrics = nil
            updateViewport()
        }
    }
    public weak var webView: WKWebView?
    public var configuration: ViewportConfiguration {
        didSet {
            updateViewport()
        }
    }
    public var metricsProvider: any ViewportMetricsProvider {
        didSet {
            lastAppliedResolvedMetrics = nil
            updateViewport()
        }
    }

    private var keyboardFrameInScreen: CGRect = .null
    private var lastAppliedResolvedMetrics: ResolvedViewportMetrics?
    private var observationView: ViewportObservationView?
    private weak var observedHostViewController: UIViewController?
    private var webViewStateCancellables: Set<AnyCancellable> = []
#if DEBUG
    private var appliedViewportUpdateCount = 0
#endif

#if DEBUG
    var resolvedMetricsForTesting: ResolvedViewportMetrics? {
        lastAppliedResolvedMetrics
    }

    var hasObservationViewForTesting: Bool {
        observationView != nil
    }

    var appliedViewportUpdateCountForTesting: Int {
        appliedViewportUpdateCount
    }

    var resolvedHostViewControllerForTesting: UIViewController? {
        resolvedHostViewController()
    }

    var observationSuperviewForTesting: UIView? {
        observationView?.superview
    }

    var observationViewForTesting: UIView? {
        observationView
    }
#endif

    public init(
        hostViewController: UIViewController? = nil,
        webView: WKWebView,
        configuration: ViewportConfiguration = .init(),
        metricsProvider: any ViewportMetricsProvider = NavigationControllerViewportMetricsProvider()
    ) {
        self.hostViewController = hostViewController
        self.webView = webView
        self.configuration = configuration
        self.metricsProvider = metricsProvider
        super.init()
        observeKeyboardNotifications()
        observeWebViewStateIfPossible()
        updateViewport()
    }

    public convenience init(
        webView: WKWebView,
        configuration: ViewportConfiguration = .init(),
        metricsProvider: any ViewportMetricsProvider = NavigationControllerViewportMetricsProvider()
    ) {
        self.init(
            hostViewController: nil,
            webView: webView,
            configuration: configuration,
            metricsProvider: metricsProvider
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func handleViewDidAppear() {
        updateViewport()
    }

    public func handleWebViewHierarchyDidChange() {
        keyboardFrameInScreen = .null
        updateViewport()
    }

    public func handleWebViewSafeAreaInsetsDidChange() {
        lastAppliedResolvedMetrics = nil
        updateViewport()
    }

    public func updateViewport() {
        guard let webView else {
            return
        }
        guard let observationContainerView = resolvedObservationContainerView() else {
            clearTransientViewportStateIfNeeded(
                resolvedHostViewController: resolvedHostViewController(),
                webView: webView
            )
            return
        }

        installObservationViewIfPossible(in: observationContainerView)
        let resolvedHostViewController = resolvedHostViewController()

        guard let resolvedHostViewController, resolvedHostViewController.view != nil else {
            clearHostResolutionStateIfNeeded(webView: webView)
            return
        }

        updateObservedHostViewControllerIfNeeded(resolvedHostViewController, webView: webView)

        applyScrollViewConfiguration(to: webView.scrollView)
        resolvedHostViewController.setContentScrollView(webView.scrollView)

        var effectiveMetrics = metricsProvider.makeViewportMetrics(
            in: resolvedHostViewController,
            webView: webView,
            keyboardOverlapHeight: keyboardOverlapHeight(),
            inputAccessoryOverlapHeight: inputAccessoryOverlapHeight()
        )
        effectiveMetrics.safeAreaAffectedEdges = configuration.safeAreaAffectedEdges

        let screenScale = observationContainerView.window?.screen.scale
            ?? webView.window?.screen.scale
            ?? observationContainerView.traitCollection.displayScale
        let resolvedMetrics = ResolvedViewportMetrics(
            state: effectiveMetrics,
            screenScale: screenScale
        )
        guard resolvedMetrics != lastAppliedResolvedMetrics else {
            return
        }

        lastAppliedResolvedMetrics = resolvedMetrics
#if DEBUG
        appliedViewportUpdateCount += 1
#endif
        if #available(iOS 26.0, *) {
            webView.obscuredContentInsets = resolvedMetrics.obscuredInsets
            ViewportSPIBridge.apply(
                unobscuredSafeAreaInsets: resolvedMetrics.unobscuredSafeAreaInsets,
                to: webView
            )
            ViewportSPIBridge.apply(
                obscuredSafeAreaEdges: resolvedMetrics.safeAreaAffectedEdges,
                to: webView
            )
        } else {
            ViewportSPIBridge.applyContentScrollInsetFallback(
                resolvedMetrics.contentScrollInsetFallback,
                to: webView.scrollView,
                webView: webView
            )
        }
    }

    public func invalidate() {
        NotificationCenter.default.removeObserver(self)
        webViewStateCancellables.removeAll()
        clearObservationViewIfNeeded()

        guard let webView else {
            return
        }

        clearObservedScrollViewIfNeeded(on: observedHostViewController ?? hostViewController, webView: webView)
        observedHostViewController = nil
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

    private func installObservationViewIfPossible() {
        guard let observationContainerView = resolvedObservationContainerView() else {
            return
        }

        installObservationViewIfPossible(in: observationContainerView)
    }

    private func installObservationViewIfPossible(in hostView: UIView) {
        if observationView?.superview === hostView {
            return
        }

        clearObservationViewIfNeeded()

        let observationView = ViewportObservationView()
        self.observationView = observationView
        observationView.onViewportGeometryChanged = { [weak self, weak observationView] in
            guard let self, let observationView, self.observationView === observationView else {
                return
            }
            self.updateViewport()
        }
        observationView.translatesAutoresizingMaskIntoConstraints = false
        observationView.isUserInteractionEnabled = false
        observationView.backgroundColor = .clear
        if #available(iOS 15.0, *) {
            observationView.keyboardLayoutGuide.followsUndockedKeyboard = true
        }
        hostView.addSubview(observationView)
        hostView.sendSubviewToBack(observationView)

        NSLayoutConstraint.activate([
            observationView.topAnchor.constraint(equalTo: hostView.topAnchor),
            observationView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            observationView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            observationView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])

        observationView.setNeedsLayout()
        observationView.layoutIfNeeded()
    }

    private func resolvedObservationContainerView() -> UIView? {
        webView?.superview
    }

    private func clearTransientViewportStateIfNeeded(
        resolvedHostViewController: UIViewController?,
        webView: WKWebView
    ) {
        clearObservedScrollViewIfNeeded(
            on: observedHostViewController ?? resolvedHostViewController,
            webView: webView
        )
        observedHostViewController = nil
        lastAppliedResolvedMetrics = nil
        clearObservationViewIfNeeded()
    }

    private func clearHostResolutionStateIfNeeded(webView: WKWebView) {
        clearObservedScrollViewIfNeeded(
            on: observedHostViewController ?? hostViewController,
            webView: webView
        )
        observedHostViewController = nil
        lastAppliedResolvedMetrics = nil
    }

    private func clearObservationViewIfNeeded() {
        observationView?.onViewportGeometryChanged = nil
        observationView?.removeFromSuperview()
        observationView = nil
    }

    private func resolvedHostViewController() -> UIViewController? {
        if let hostViewController {
            return hostViewController
        }
        guard let webView else {
            return nil
        }

        var responder: UIResponder? = webView
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }

        return webView.window?.rootViewController
    }

    private func updateObservedHostViewControllerIfNeeded(
        _ resolvedHostViewController: UIViewController,
        webView: WKWebView
    ) {
        guard observedHostViewController !== resolvedHostViewController else {
            return
        }

        clearObservedScrollViewIfNeeded(on: observedHostViewController, webView: webView)
        observedHostViewController = resolvedHostViewController
    }

    private func clearObservedScrollViewIfNeeded(on hostViewController: UIViewController?, webView: WKWebView) {
        guard let hostViewController else {
            return
        }

        if hostViewController.contentScrollView(for: .top) === webView.scrollView
            || hostViewController.contentScrollView(for: .bottom) === webView.scrollView {
            hostViewController.setContentScrollView(nil)
        }
    }

    private func observeWebViewStateIfPossible() {
        guard let webView else {
            return
        }

        webView.publisher(for: \.isLoading, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleObservedWebViewStateChange()
            }
            .store(in: &webViewStateCancellables)

        webView.publisher(for: \.url, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleObservedWebViewStateChange()
            }
            .store(in: &webViewStateCancellables)
    }

    private func handleObservedWebViewStateChange() {
        lastAppliedResolvedMetrics = nil
        updateViewport()
    }

#if DEBUG
    func handleObservedWebViewStateChangeForTesting() {
        handleObservedWebViewStateChange()
    }
#endif

    private func keyboardOverlapHeight() -> CGFloat {
        let frameIntersectionHeight: CGFloat
        if
            let hostView = resolvedHostViewController()?.view,
            let window = hostView.window,
            keyboardFrameInScreen.isNull == false
        {
            let keyboardFrameInWindow = window.convert(
                keyboardFrameInScreen,
                from: window.screen.coordinateSpace
            )
            let keyboardFrameInHostView = hostView.convert(keyboardFrameInWindow, from: nil)
            frameIntersectionHeight = max(0, hostView.bounds.intersection(keyboardFrameInHostView).height)
        } else {
            frameIntersectionHeight = 0
        }

        return max(frameIntersectionHeight, keyboardLayoutGuideCoverageHeight())
    }

    private func keyboardLayoutGuideCoverageHeight() -> CGFloat {
        guard let observationView else {
            return 0
        }

        if #available(iOS 15.0, *) {
            let layoutFrame = observationView.keyboardLayoutGuide.layoutFrame
            guard layoutFrame.isEmpty == false else {
                return 0
            }
            return max(0, observationView.bounds.intersection(layoutFrame).height)
        }

        return 0
    }

    private func inputAccessoryOverlapHeight() -> CGFloat {
        guard
            let hostView = resolvedHostViewController()?.view,
            let window = hostView.window,
            let webView,
            let inputViewBoundsInWindow = ViewportSPIBridge.inputViewBoundsInWindow(of: webView)
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
        updateViewport()
    }
}

@MainActor
private final class ViewportObservationView: UIView {
    var onViewportGeometryChanged: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onViewportGeometryChanged?()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onViewportGeometryChanged?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onViewportGeometryChanged?()
    }
}

private extension UIEdgeInsets {
    func wk_roundedToPixel(_ screenScale: CGFloat) -> UIEdgeInsets {
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
private extension ScrollEdgeEffectStyle {
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

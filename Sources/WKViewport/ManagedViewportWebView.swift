#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class ManagedViewportWebView: WKWebView {
    public weak var viewportHostViewController: UIViewController? {
        didSet {
            viewportCoordinator?.hostViewController = viewportHostViewController
        }
    }

    public var viewportConfiguration = ViewportConfiguration() {
        didSet {
            viewportCoordinator?.configuration = viewportConfiguration
        }
    }

    public var viewportMetricsProvider: any ViewportMetricsProvider = NavigationControllerViewportMetricsProvider() {
        didSet {
            viewportCoordinator?.metricsProvider = viewportMetricsProvider
        }
    }

    private var viewportCoordinator: ViewportCoordinator?

    public override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        installViewportCoordinator()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        installViewportCoordinator()
    }

    isolated deinit {
        viewportCoordinator?.invalidate()
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        viewportCoordinator?.handleWebViewHierarchyDidChange()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        viewportCoordinator?.handleWebViewHierarchyDidChange()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        viewportCoordinator?.handleWebViewSafeAreaInsetsDidChange()
    }

    var activeViewportCoordinatorForTesting: ViewportCoordinator? {
        viewportCoordinator
    }

#if DEBUG
    var resolvedHostViewControllerForTesting: UIViewController? {
        viewportCoordinator?.resolvedHostViewControllerForTesting
    }
#endif

    private func installViewportCoordinator() {
        viewportCoordinator = ViewportCoordinator(
            hostViewController: viewportHostViewController,
            webView: self,
            configuration: viewportConfiguration,
            metricsProvider: viewportMetricsProvider
        )
    }
}
#endif

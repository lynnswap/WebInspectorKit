#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class ManagedViewportWebView: WKWebView {
    public weak var viewportHostViewController: UIViewController? {
        didSet {
            refreshViewportCoordinator(forceRebuild: true)
        }
    }

    public var viewportConfiguration = ViewportConfiguration() {
        didSet {
            refreshViewportCoordinator()
        }
    }

    public var viewportMetricsProvider: any ViewportMetricsProvider = NavigationControllerViewportMetricsProvider() {
        didSet {
            refreshViewportCoordinator()
        }
    }

    private var viewportCoordinator: ViewportCoordinator?

    public override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        refreshViewportCoordinator()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        refreshViewportCoordinator()
    }

    isolated deinit {
        viewportCoordinator?.invalidate()
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        refreshViewportCoordinator()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshViewportCoordinator()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        refreshViewportCoordinator()
    }

    var activeViewportCoordinatorForTesting: ViewportCoordinator? {
        viewportCoordinator
    }

    var resolvedHostViewControllerForTesting: UIViewController? {
        resolvedViewportHostViewController()
    }

    private func refreshViewportCoordinator(forceRebuild: Bool = false) {
        let resolvedHostViewController = resolvedViewportHostViewController()
        let needsRebuild = forceRebuild
            || viewportCoordinator == nil
            || viewportCoordinator?.hostViewController !== resolvedHostViewController

        if needsRebuild {
            viewportCoordinator?.invalidate()
            viewportCoordinator = nil

            guard let resolvedHostViewController else {
                return
            }

            viewportCoordinator = ViewportCoordinator(
                hostViewController: resolvedHostViewController,
                webView: self,
                configuration: viewportConfiguration,
                metricsProvider: viewportMetricsProvider
            )
        }

        guard let viewportCoordinator else {
            return
        }

        viewportCoordinator.configuration = viewportConfiguration
        viewportCoordinator.metricsProvider = viewportMetricsProvider
        viewportCoordinator.updateViewport()
    }

    private func resolvedViewportHostViewController() -> UIViewController? {
        if let viewportHostViewController {
            return viewportHostViewController
        }

        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }

        return window?.rootViewController
    }
}
#endif

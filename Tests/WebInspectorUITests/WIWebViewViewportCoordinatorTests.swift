#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WebInspectorUI

@MainActor
struct WIWebViewViewportCoordinatorTests {
    @Test
    func resolvedMetricsRoundInsetsToPixelBoundaries() {
        let first = WIWebViewChromeResolvedMetrics(
            state: WIWebViewChromeMetrics(
                safeAreaInsets: UIEdgeInsets(top: 58.97, left: 0, bottom: 34.02, right: 0),
                topObscuredHeight: 102.98,
                bottomObscuredHeight: 87.96,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        let second = WIWebViewChromeResolvedMetrics(
            state: WIWebViewChromeMetrics(
                safeAreaInsets: UIEdgeInsets(top: 59.01, left: 0, bottom: 34.04, right: 0),
                topObscuredHeight: 103.01,
                bottomObscuredHeight: 87.99,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        #expect(first == second)
        #expect(first.obscuredInsets.top == 103)
        #expect(first.obscuredInsets.bottom == 88)
    }

    @Test
    func navigationMetricsProviderUsesHostSafeAreaInsets() {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let navigationController = UINavigationController(rootViewController: hostViewController)
        navigationController.setToolbarHidden(false, animated: false)
        let window = makeWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostViewController.view.frame = window.bounds
        hostViewController.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()

        let metrics = WINavigationControllerChromeMetricsProvider().makeChromeMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == hostViewController.view.safeAreaInsets)
        #expect(metrics.topObscuredHeight == hostViewController.view.safeAreaInsets.top)
        #expect(metrics.bottomObscuredHeight == hostViewController.view.safeAreaInsets.bottom)
    }

    @Test
    @available(iOS 26.0, *)
    func coordinatorAppliesStandardScrollConfigurationAndViewportInsets() {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        hostViewController.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: hostViewController.view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor)
        ])

        let navigationController = UINavigationController(rootViewController: hostViewController)
        navigationController.setToolbarHidden(false, animated: false)
        let window = makeWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        navigationController.view.layoutIfNeeded()
        hostViewController.view.layoutIfNeeded()

        let coordinator = WIWebViewViewportCoordinator(
            hostViewController: hostViewController,
            webView: webView
        )
        coordinator.handleViewDidAppear()
        coordinator.updateChromeState()

        let resolved = try #require(coordinator.resolvedMetricsForTesting)
        #expect(webView.scrollView.contentInsetAdjustmentBehavior == .always)
        #expect(webView.scrollView.topEdgeEffect.isHidden == false)
        #expect(webView.scrollView.bottomEdgeEffect.isHidden == false)
        #expect(webView.scrollView.topEdgeEffect.style == .soft)
        #expect(webView.scrollView.bottomEdgeEffect.style == .soft)
        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
        #expect(hostViewController.contentScrollView(for: .bottom) === webView.scrollView)
        #expect(webView.obscuredContentInsets == resolved.obscuredInsets)
    }

    @Test
    func viewportSPIBridgeNoOpsWhenSelectorsAreUnavailable() {
        let plainObject = NSObject()

        WIWebViewViewportSPIBridge.apply(unobscuredSafeAreaInsets: .zero, to: plainObject)
        WIWebViewViewportSPIBridge.apply(obscuredSafeAreaEdges: [.top, .bottom], to: plainObject)

        #expect(WIWebViewViewportSPIBridge.inputViewBoundsInWindow(of: plainObject) == nil)
    }
}

@MainActor
private func makeWindow(rootViewController: UIViewController) -> UIWindow {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}
#endif

#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WebInspectorBridge
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
    func coordinatorInstallsObservationViewWhenHostViewLoadsAfterInitialization() {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        let coordinator = WIWebViewViewportCoordinator(
            hostViewController: hostViewController,
            webView: webView
        )
        #expect(coordinator.hasObservationViewForTesting == false)

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

        coordinator.handleViewDidAppear()

        #expect(coordinator.hasObservationViewForTesting == true)
        #expect(coordinator.resolvedMetricsForTesting != nil)
    }

    @Test
    func coordinatorRegistersHostedScrollViewForNavigationChrome() {
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

        let coordinator = WIWebViewViewportCoordinator(
            hostViewController: hostViewController,
            webView: webView
        )

        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
        #expect(hostViewController.contentScrollView(for: .bottom) === webView.scrollView)
        coordinator.invalidate()
        #expect(hostViewController.contentScrollView(for: .top) == nil)
        #expect(hostViewController.contentScrollView(for: .bottom) == nil)
    }

    @Test
    @available(iOS 26.0, *)
    func coordinatorReappliesViewportWhenNavigationStateChangesWithoutGeometryChange() throws {
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

        let coordinator = WIWebViewViewportCoordinator(
            hostViewController: hostViewController,
            webView: webView
        )
        let initialCount = coordinator.appliedViewportUpdateCountForTesting
        #expect(initialCount > 0)

        coordinator.handleObservedWebViewStateChangeForTesting()

        #expect(coordinator.appliedViewportUpdateCountForTesting == initialCount + 1)
        _ = try #require(coordinator.resolvedMetricsForTesting)
    }

    @Test
    func resolvedMetricsDeriveContentScrollInsetFallbackFromSafeAreaDelta() {
        let resolvedMetrics = WIWebViewChromeResolvedMetrics(
            state: WIWebViewChromeMetrics(
                safeAreaInsets: UIEdgeInsets(top: 59, left: 4, bottom: 34, right: 6),
                topObscuredHeight: 103,
                bottomObscuredHeight: 88,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        #expect(
            resolvedMetrics.contentScrollInsetFallback == UIEdgeInsets(top: 44, left: 0, bottom: 54, right: 0)
        )
    }

    @Test
    func viewportSPIBridgeFallbackNoOpsWhenSelectorsAreUnavailable() {
        let plainObject = NSObject()
        let resolvedMetrics = WIWebViewChromeResolvedMetrics(
            state: WIWebViewChromeMetrics(
                safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                topObscuredHeight: 103,
                bottomObscuredHeight: 88,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        #expect(
            WIWebViewViewportSPIBridge.applyContentScrollInsetFallback(
                resolvedMetrics.contentScrollInsetFallback,
                to: plainObject,
                webView: plainObject
            ) == false
        )
        WIWebViewViewportSPIBridge.apply(unobscuredSafeAreaInsets: .zero, to: plainObject)
        WIWebViewViewportSPIBridge.apply(obscuredSafeAreaEdges: [.top, .bottom], to: plainObject)

        #expect(WIWebViewViewportSPIBridge.inputViewBoundsInWindow(of: plainObject) == nil)
    }

    @Test
    func viewportSPIBridgeContentScrollInsetFallbackAppliesExpectedSelectorsInOrder() {
        let object = TestViewportSPIObject()
        let resolvedMetrics = WIWebViewChromeResolvedMetrics(
            state: WIWebViewChromeMetrics(
                safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
                topObscuredHeight: 103,
                bottomObscuredHeight: 88,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        #expect(
            WIWebViewViewportSPIBridge.applyContentScrollInsetFallback(
                resolvedMetrics.contentScrollInsetFallback,
                to: object,
                webView: object
            )
        )
        #expect(object.contentScrollInsetCalls == [resolvedMetrics.contentScrollInsetFallback])
        #expect(object.frameOrBoundsMayHaveChangedCallCount == 1)
        #expect(
            object.invocationOrder == [
                WISPISymbols.setContentScrollInsetSelector,
                WISPISymbols.frameOrBoundsMayHaveChangedSelector
            ]
        )
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

private final class TestViewportSPIObject: NSObject {
    private(set) var contentScrollInsetCalls: [UIEdgeInsets] = []
    private(set) var frameOrBoundsMayHaveChangedCallCount = 0
    private(set) var invocationOrder: [String] = []

    @objc(_setContentScrollInset:)
    func setContentScrollInset(_ insets: UIEdgeInsets) {
        invocationOrder.append(WISPISymbols.setContentScrollInsetSelector)
        contentScrollInsetCalls.append(insets)
    }

    @objc(_frameOrBoundsMayHaveChanged)
    func frameOrBoundsMayHaveChanged() {
        invocationOrder.append(WISPISymbols.frameOrBoundsMayHaveChangedSelector)
        frameOrBoundsMayHaveChangedCallCount += 1
    }
}
#endif

#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
import WebKit
@testable import WKViewport

@MainActor
struct ViewportCoordinatorTests {
    @Test
    func resolvedMetricsRoundInsetsToPixelBoundaries() {
        let first = ResolvedViewportMetrics(
            state: ViewportMetrics(
                safeAreaInsets: UIEdgeInsets(top: 58.97, left: 0, bottom: 34.02, right: 0),
                topObscuredHeight: 102.98,
                bottomObscuredHeight: 87.96,
                keyboardOverlapHeight: 0,
                inputAccessoryOverlapHeight: 0,
                bottomChromeMode: .normal
            ),
            screenScale: 3
        )

        let second = ResolvedViewportMetrics(
            state: ViewportMetrics(
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

        let metrics = NavigationControllerViewportMetricsProvider().makeViewportMetrics(
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
        let coordinator = ViewportCoordinator(
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
        #expect(coordinator.observationSuperviewForTesting === hostViewController.view)
        #expect(coordinator.resolvedMetricsForTesting != nil)
    }

    @Test
    func coordinatorResolvesHostViewControllerFromResponderChain() {
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

        let coordinator = ViewportCoordinator(webView: webView)

        #expect(coordinator.resolvedHostViewControllerForTesting === hostViewController)
        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
        coordinator.invalidate()
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

        let coordinator = ViewportCoordinator(webView: webView)

        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
        #expect(hostViewController.contentScrollView(for: .bottom) === webView.scrollView)
        coordinator.invalidate()
        #expect(hostViewController.contentScrollView(for: .top) == nil)
        #expect(hostViewController.contentScrollView(for: .bottom) == nil)
    }

    @Test
    func coordinatorUsesSwiftUIContainerAsObservationSuperview() async throws {
        let webView = WKWebView(frame: .zero)
        let box = ContainerViewBox()
        let hostingController = UIHostingController(
            rootView: HostingWebViewContainer(webView: webView, box: box)
        )
        let window = makeWindow(rootViewController: hostingController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostingController.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(10))

        let containerView = try #require(box.view)
        let coordinator = ViewportCoordinator(webView: webView)

        coordinator.updateViewport()

        #expect(coordinator.resolvedHostViewControllerForTesting === hostingController)
        #expect(coordinator.observationSuperviewForTesting === containerView)
        #expect(coordinator.observationSuperviewForTesting !== hostingController.view)
        #expect(hostingController.contentScrollView(for: .top) === webView.scrollView)
        #expect(hostingController.contentScrollView(for: .bottom) === webView.scrollView)
        coordinator.invalidate()
    }

    @Test
    func coordinatorReusesObservationViewWhileSuperviewIsStable() {
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

        let window = makeWindow(rootViewController: hostViewController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)
        let firstObservationView = coordinator.observationViewForTesting
        let firstSuperview = coordinator.observationSuperviewForTesting

        coordinator.updateViewport()
        coordinator.updateViewport()

        #expect(coordinator.observationViewForTesting === firstObservationView)
        #expect(coordinator.observationSuperviewForTesting === firstSuperview)
        coordinator.invalidate()
    }

    @Test
    func coordinatorMovesObservationViewWhenWebViewSuperviewChanges() {
        let hostViewController = UIViewController()
        let firstContainer = UIView()
        let secondContainer = UIView()
        let webView = WKWebView(frame: .zero)
        [firstContainer, secondContainer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            hostViewController.view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            firstContainer.topAnchor.constraint(equalTo: hostViewController.view.topAnchor),
            firstContainer.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            firstContainer.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            firstContainer.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor),
            secondContainer.topAnchor.constraint(equalTo: hostViewController.view.topAnchor),
            secondContainer.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            secondContainer.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            secondContainer.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor),
        ])

        let firstConstraints = attach(webView, to: firstContainer)

        let window = makeWindow(rootViewController: hostViewController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)
        #expect(coordinator.observationSuperviewForTesting === firstContainer)

        webView.removeFromSuperview()
        NSLayoutConstraint.deactivate(firstConstraints)
        attach(webView, to: secondContainer)
        hostViewController.view.layoutIfNeeded()

        coordinator.updateViewport()

        #expect(coordinator.observationSuperviewForTesting === secondContainer)
        coordinator.invalidate()
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

        let coordinator = ViewportCoordinator(webView: webView)
        let initialCount = coordinator.appliedViewportUpdateCountForTesting
        #expect(initialCount > 0)

        coordinator.handleObservedWebViewStateChangeForTesting()

        #expect(coordinator.appliedViewportUpdateCountForTesting == initialCount + 1)
        _ = try #require(coordinator.resolvedMetricsForTesting)
    }

    @Test
    func resolvedMetricsDeriveContentScrollInsetFallbackFromSafeAreaDelta() {
        let resolvedMetrics = ResolvedViewportMetrics(
            state: ViewportMetrics(
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
        let resolvedMetrics = ResolvedViewportMetrics(
            state: ViewportMetrics(
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
            ViewportSPIBridge.applyContentScrollInsetFallback(
                resolvedMetrics.contentScrollInsetFallback,
                to: plainObject,
                webView: plainObject
            ) == false
        )
        ViewportSPIBridge.apply(unobscuredSafeAreaInsets: .zero, to: plainObject)
        ViewportSPIBridge.apply(obscuredSafeAreaEdges: [.top, .bottom], to: plainObject)

        #expect(ViewportSPIBridge.inputViewBoundsInWindow(of: plainObject) == nil)
    }

    @Test
    func viewportSPIBridgeContentScrollInsetFallbackAppliesExpectedSelectorsInOrder() {
        let object = TestViewportSPIObject()
        let resolvedMetrics = ResolvedViewportMetrics(
            state: ViewportMetrics(
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
            ViewportSPIBridge.applyContentScrollInsetFallback(
                resolvedMetrics.contentScrollInsetFallback,
                to: object,
                webView: object
            )
        )
        #expect(object.contentScrollInsetCalls == [resolvedMetrics.contentScrollInsetFallback])
        #expect(object.frameOrBoundsMayHaveChangedCallCount == 1)
        #expect(
            object.invocationOrder == [
                ViewportSPISelectorNames.setContentScrollInset,
                ViewportSPISelectorNames.frameOrBoundsMayHaveChanged
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
        invocationOrder.append(ViewportSPISelectorNames.setContentScrollInset)
        contentScrollInsetCalls.append(insets)
    }

    @objc(_frameOrBoundsMayHaveChanged)
    func frameOrBoundsMayHaveChanged() {
        invocationOrder.append(ViewportSPISelectorNames.frameOrBoundsMayHaveChanged)
        frameOrBoundsMayHaveChangedCallCount += 1
    }
}

@MainActor
private final class ContainerViewBox {
    var view: UIView?
}

private struct HostingWebViewContainer: View {
    let webView: WKWebView
    let box: ContainerViewBox

    var body: some View {
        HostingWebViewRepresentable(webView: webView, box: box)
    }
}

private struct HostingWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    let box: ContainerViewBox

    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        box.view = containerView
        attach(webView, to: containerView)
        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
@discardableResult
private func attach(_ webView: WKWebView, to containerView: UIView) -> [NSLayoutConstraint] {
    webView.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(webView)
    let constraints = [
        webView.topAnchor.constraint(equalTo: containerView.topAnchor),
        webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
        webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
    ]
    NSLayoutConstraint.activate(constraints)
    return constraints
}
#endif

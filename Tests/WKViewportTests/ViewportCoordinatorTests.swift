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
    func uiKitChromeMetricsProviderUsesProjectedWindowSafeAreaWhenNoChromeOverlaps() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let window = makeWindow(rootViewController: hostViewController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostViewController.view.frame = window.bounds
        hostViewController.view.layoutIfNeeded()
        window.layoutIfNeeded()

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == projectedWindowSafeAreaInsets(in: try #require(webView.superview)))
        #expect(metrics.topObscuredHeight == 0)
        #expect(metrics.bottomObscuredHeight == 0)
    }

    @Test
    func uiKitChromeMetricsProviderIncludesVisibleNavigationBarOverlap() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let navigationController = UINavigationController(rootViewController: hostViewController)
        navigationController.setNavigationBarHidden(false, animated: false)
        let window = makeWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostViewController.view.frame = window.bounds
        hostViewController.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == projectedWindowSafeAreaInsets(in: try #require(webView.superview)))
        #expect(
            metrics.topObscuredHeight
                == topEdgeObscuredHeight(of: navigationController.navigationBar, in: try #require(webView.superview))
        )
    }

    @Test
    func uiKitChromeMetricsProviderIncludesVisibleTabBarOverlap() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let tabBarController = UITabBarController()
        tabBarController.setViewControllers([hostViewController], animated: false)
        let window = makeWindow(rootViewController: tabBarController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostViewController.view.frame = tabBarController.view.bounds
        hostViewController.view.layoutIfNeeded()
        tabBarController.view.layoutIfNeeded()

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == projectedWindowSafeAreaInsets(in: try #require(webView.superview)))
        #expect(
            metrics.bottomObscuredHeight
                == bottomEdgeObscuredHeight(of: tabBarController.tabBar, in: try #require(webView.superview))
        )
    }

    @Test
    func uiKitChromeMetricsProviderIncludesVisibleToolbarOverlap() throws {
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

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(
            metrics.bottomObscuredHeight
                == bottomEdgeObscuredHeight(of: navigationController.toolbar, in: try #require(webView.superview))
        )
    }

    @Test
    func uiKitChromeMetricsProviderIgnoresHiddenTabBarOverlap() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let tabBarController = UITabBarController()
        tabBarController.setViewControllers([hostViewController], animated: false)
        let window = makeWindow(rootViewController: tabBarController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        tabBarController.tabBar.isHidden = true
        tabBarController.tabBar.alpha = 0
        hostViewController.view.layoutIfNeeded()
        tabBarController.view.layoutIfNeeded()

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == projectedWindowSafeAreaInsets(in: try #require(webView.superview)))
        #expect(metrics.bottomObscuredHeight == 0)
    }

    @Test
    func uiKitChromeMetricsProviderIgnoresTabBarThatDoesNotReachBottomEdge() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let tabBarController = UITabBarController()
        tabBarController.setViewControllers([hostViewController], animated: false)
        let window = makeWindow(rootViewController: tabBarController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostViewController.view.frame = tabBarController.view.bounds
        hostViewController.view.layoutIfNeeded()
        tabBarController.view.layoutIfNeeded()

        var tabBarFrame = tabBarController.tabBar.frame
        tabBarFrame.origin.y = hostViewController.view.bounds.minY
        tabBarController.tabBar.frame = tabBarFrame

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.bottomObscuredHeight == 0)
    }

    @Test
    func uiKitChromeMetricsProviderIgnoresAdditionalSafeAreaInsets() {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.view.addSubview(webView)

        let tabBarController = UITabBarController()
        tabBarController.setViewControllers([hostViewController], animated: false)
        let window = makeWindow(rootViewController: tabBarController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let provider = UIKitChromeViewportMetricsProvider()
        let baseline = provider.makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        hostViewController.additionalSafeAreaInsets = UIEdgeInsets(top: 16, left: 0, bottom: 48, right: 0)
        hostViewController.view.setNeedsLayout()
        hostViewController.view.layoutIfNeeded()
        tabBarController.view.layoutIfNeeded()

        let updated = provider.makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(updated == baseline)
    }

    @Test
    func uiKitChromeMetricsProviderProjectsWindowSafeAreaIntoContainerSubview() throws {
        let rootViewController = UIViewController()
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        hostViewController.loadViewIfNeeded()
        rootViewController.addChild(hostViewController)
        rootViewController.view.addSubview(hostViewController.view)
        hostViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostViewController.view.topAnchor.constraint(equalTo: rootViewController.view.safeAreaLayoutGuide.topAnchor),
            hostViewController.view.leadingAnchor.constraint(equalTo: rootViewController.view.safeAreaLayoutGuide.leadingAnchor),
            hostViewController.view.trailingAnchor.constraint(equalTo: rootViewController.view.safeAreaLayoutGuide.trailingAnchor),
            hostViewController.view.bottomAnchor.constraint(equalTo: rootViewController.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        hostViewController.didMove(toParent: rootViewController)
        attach(webView, to: hostViewController.view)

        let window = makeWindow(rootViewController: rootViewController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        rootViewController.view.layoutIfNeeded()
        hostViewController.view.layoutIfNeeded()

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == projectedWindowSafeAreaInsets(in: try #require(webView.superview)))
        #expect(metrics.topObscuredHeight == 0)
        #expect(metrics.bottomObscuredHeight == 0)
    }

    @Test
    func uiKitChromeMetricsProviderUsesWebViewSuperviewWhenSwiftUIInsetsViewport() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        let viewportContainer = UIView()
        viewportContainer.translatesAutoresizingMaskIntoConstraints = false
        hostViewController.view.addSubview(viewportContainer)
        NSLayoutConstraint.activate([
            viewportContainer.topAnchor.constraint(equalTo: hostViewController.view.safeAreaLayoutGuide.topAnchor),
            viewportContainer.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            viewportContainer.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            viewportContainer.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor),
        ])
        attach(webView, to: viewportContainer)

        let navigationController = UINavigationController(rootViewController: hostViewController)
        navigationController.setNavigationBarHidden(false, animated: false)
        let window = makeWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostViewController.view.layoutIfNeeded()
        navigationController.view.layoutIfNeeded()

        let metrics = UIKitChromeViewportMetricsProvider().makeViewportMetrics(
            in: hostViewController,
            webView: webView,
            keyboardOverlapHeight: 0,
            inputAccessoryOverlapHeight: 0
        )

        #expect(metrics.safeAreaInsets == projectedWindowSafeAreaInsets(in: viewportContainer))
        #expect(metrics.topObscuredHeight == topEdgeObscuredHeight(of: navigationController.navigationBar, in: viewportContainer))
        #expect(metrics.topObscuredHeight == 0)
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

        coordinator.handleWebViewHierarchyDidChange()

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

        #expect(coordinator.observationViewForTesting === firstObservationView)
        #expect(coordinator.observationSuperviewForTesting === firstSuperview)
        coordinator.invalidate()
    }

    @Test
    func coordinatorRefreshesWhenSameHostViewControllerIsAssignedAgain() {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        attach(webView, to: hostViewController.view)

        let window = makeWindow(rootViewController: hostViewController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(hostViewController: hostViewController, webView: webView)
        let initialUpdateCount = coordinator.appliedViewportUpdateCountForTesting

        coordinator.hostViewController = hostViewController

        #expect(coordinator.appliedViewportUpdateCountForTesting == initialUpdateCount + 1)
        #expect(coordinator.resolvedHostViewControllerForTesting === hostViewController)
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
        coordinator.handleWebViewHierarchyDidChange()

        #expect(coordinator.observationSuperviewForTesting === secondContainer)
        coordinator.invalidate()
    }

    @Test
    func coordinatorPreservesKeyboardOverlapWhenWebViewReparents() throws {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        let firstContainer = UIView()
        let secondContainer = UIView()
        for container in [firstContainer, secondContainer] {
            container.translatesAutoresizingMaskIntoConstraints = false
            hostViewController.view.addSubview(container)
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
            postKeyboardFrameChange(.null)
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)
        let keyboardFrame = CGRect(
            x: 0,
            y: window.bounds.maxY - 240,
            width: window.bounds.width,
            height: 240
        )
        postKeyboardFrameChange(keyboardFrame)

        let initialMetrics = try #require(coordinator.resolvedMetricsForTesting)
        #expect(initialMetrics.obscuredInsets.bottom == 240)

        webView.removeFromSuperview()
        NSLayoutConstraint.deactivate(firstConstraints)
        attach(webView, to: secondContainer)
        hostViewController.view.layoutIfNeeded()
        coordinator.handleWebViewHierarchyDidChange()

        let updatedMetrics = try #require(coordinator.resolvedMetricsForTesting)
        #expect(updatedMetrics.obscuredInsets.bottom == initialMetrics.obscuredInsets.bottom)
        coordinator.invalidate()
    }

    @Test
    func coordinatorClearsKeyboardOverlapWhenWebViewMovesToDifferentWindow() throws {
        let firstHostViewController = UIViewController()
        let firstContainer = UIView()
        firstContainer.translatesAutoresizingMaskIntoConstraints = false
        firstHostViewController.view.addSubview(firstContainer)
        NSLayoutConstraint.activate([
            firstContainer.topAnchor.constraint(equalTo: firstHostViewController.view.topAnchor),
            firstContainer.leadingAnchor.constraint(equalTo: firstHostViewController.view.leadingAnchor),
            firstContainer.trailingAnchor.constraint(equalTo: firstHostViewController.view.trailingAnchor),
            firstContainer.bottomAnchor.constraint(equalTo: firstHostViewController.view.bottomAnchor),
        ])

        let secondHostViewController = UIViewController()
        let secondContainer = UIView()
        secondContainer.translatesAutoresizingMaskIntoConstraints = false
        secondHostViewController.view.addSubview(secondContainer)
        NSLayoutConstraint.activate([
            secondContainer.topAnchor.constraint(equalTo: secondHostViewController.view.topAnchor),
            secondContainer.leadingAnchor.constraint(equalTo: secondHostViewController.view.leadingAnchor),
            secondContainer.trailingAnchor.constraint(equalTo: secondHostViewController.view.trailingAnchor),
            secondContainer.bottomAnchor.constraint(equalTo: secondHostViewController.view.bottomAnchor),
        ])

        let webView = WKWebView(frame: .zero)
        let firstConstraints = attach(webView, to: firstContainer)

        let firstWindow = makeWindow(rootViewController: firstHostViewController)
        let secondWindow = makeWindow(rootViewController: secondHostViewController)
        defer {
            postKeyboardFrameChange(.null)
            firstWindow.isHidden = true
            firstWindow.rootViewController = nil
            secondWindow.isHidden = true
            secondWindow.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)
        let keyboardFrame = CGRect(
            x: 0,
            y: firstWindow.bounds.maxY - 240,
            width: firstWindow.bounds.width,
            height: 240
        )
        postKeyboardFrameChange(keyboardFrame)

        let initialMetrics = try #require(coordinator.resolvedMetricsForTesting)
        #expect(initialMetrics.obscuredInsets.bottom == 240)

        webView.removeFromSuperview()
        NSLayoutConstraint.deactivate(firstConstraints)
        attach(webView, to: secondContainer)
        secondHostViewController.view.layoutIfNeeded()
        coordinator.handleWebViewHierarchyDidChange()

        let updatedMetrics = try #require(coordinator.resolvedMetricsForTesting)
        #expect(updatedMetrics.obscuredInsets.bottom == 0)
        coordinator.invalidate()
    }

    @Test
    func coordinatorClearsObservedScrollViewWhenHostResolutionFails() {
        let hostViewController = UIViewController()
        let webView = WKWebView(frame: .zero)
        let hostedConstraints = attach(webView, to: hostViewController.view)

        let window = makeWindow(rootViewController: hostViewController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)
        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)

        let orphanContainer = UIView()
        NSLayoutConstraint.deactivate(hostedConstraints)
        attach(webView, to: orphanContainer)
        coordinator.handleWebViewHierarchyDidChange()

        #expect(hostViewController.contentScrollView(for: .top) == nil)
        #expect(hostViewController.contentScrollView(for: .bottom) == nil)
        #expect(coordinator.observationSuperviewForTesting === orphanContainer)
        coordinator.invalidate()
    }

    @Test
    func coordinatorUpdatesCustomSubclassWithExplicitLifecycleForwarding() {
        let hostViewController = UIViewController()
        let navigationController = UINavigationController(rootViewController: hostViewController)
        let window = makeWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let webView = CustomViewportTestWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let coordinator = ViewportCoordinator(webView: webView)
        webView.viewportCoordinator = coordinator

        attach(webView, to: hostViewController.view)
        hostViewController.view.layoutIfNeeded()

        #expect(coordinator.resolvedHostViewControllerForTesting === hostViewController)
        #expect(coordinator.observationSuperviewForTesting === hostViewController.view)
        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
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

@MainActor
private final class CustomViewportTestWebView: WKWebView {
    weak var viewportCoordinator: ViewportCoordinator?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        viewportCoordinator?.handleWebViewHierarchyDidChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        viewportCoordinator?.handleWebViewHierarchyDidChange()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        viewportCoordinator?.handleWebViewSafeAreaInsetsDidChange()
    }
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

@MainActor
private func projectedWindowSafeAreaInsets(in hostView: UIView) -> UIEdgeInsets {
    guard let window = hostView.window else {
        return .zero
    }

    let hostRectInWindow = hostView.convert(hostView.bounds, to: window)
    let safeRectInWindow = window.bounds.inset(by: window.safeAreaInsets)

    return UIEdgeInsets(
        top: max(0, safeRectInWindow.minY - hostRectInWindow.minY),
        left: max(0, safeRectInWindow.minX - hostRectInWindow.minX),
        bottom: max(0, hostRectInWindow.maxY - safeRectInWindow.maxY),
        right: max(0, hostRectInWindow.maxX - safeRectInWindow.maxX)
    )
}

@MainActor
private func postKeyboardFrameChange(_ frame: CGRect) {
    NotificationCenter.default.post(
        name: UIResponder.keyboardWillChangeFrameNotification,
        object: nil,
        userInfo: [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)
        ]
    )
}

@MainActor
private func topEdgeObscuredHeight(of chromeView: UIView?, in hostView: UIView) -> CGFloat {
    guard let chromeView else {
        return 0
    }
    guard let window = hostView.window, chromeView.window != nil else {
        return 0
    }
    guard chromeView.isHidden == false, effectiveAlpha(of: chromeView) > 0 else {
        return 0
    }

    let hostFrameInWindow = hostView.convert(hostView.bounds, to: window)
    let chromeFrameInWindow = chromeView.convert(chromeView.bounds, to: window)
    guard hostFrameInWindow.intersects(chromeFrameInWindow) || chromeFrameInWindow.maxY > hostFrameInWindow.minY else {
        return 0
    }

    return max(0, min(hostFrameInWindow.maxY, chromeFrameInWindow.maxY) - hostFrameInWindow.minY)
}

@MainActor
private func bottomEdgeObscuredHeight(of chromeView: UIView?, in hostView: UIView) -> CGFloat {
    guard let chromeView else {
        return 0
    }
    guard let window = hostView.window, chromeView.window != nil else {
        return 0
    }
    guard chromeView.isHidden == false, effectiveAlpha(of: chromeView) > 0 else {
        return 0
    }

    let hostFrameInWindow = hostView.convert(hostView.bounds, to: window)
    let chromeFrameInWindow = chromeView.convert(chromeView.bounds, to: window)
    guard chromeFrameInWindow.minY < hostFrameInWindow.maxY else {
        return 0
    }
    guard chromeFrameInWindow.maxY >= hostFrameInWindow.maxY else {
        return 0
    }

    return max(0, hostFrameInWindow.maxY - max(hostFrameInWindow.minY, chromeFrameInWindow.minY))
}

@MainActor
private func effectiveAlpha(of view: UIView) -> CGFloat {
    var alpha = view.alpha
    var currentSuperview = view.superview

    while let superview = currentSuperview {
        if superview.isHidden {
            return 0
        }
        alpha *= superview.alpha
        currentSuperview = superview.superview
    }

    return alpha
}
#endif

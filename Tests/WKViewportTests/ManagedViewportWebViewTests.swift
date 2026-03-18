#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WKViewport

@MainActor
struct ManagedViewportWebViewTests {
    @Test
    func managedViewportWebViewFindsHostViewControllerAutomatically() {
        let hostViewController = UIViewController()
        let navigationController = UINavigationController(rootViewController: hostViewController)
        let window = makeManagedViewportWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let webView = ManagedViewportWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        webView.translatesAutoresizingMaskIntoConstraints = false
        hostViewController.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: hostViewController.view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor)
        ])

        hostViewController.view.layoutIfNeeded()

        #expect(webView.resolvedHostViewControllerForTesting === hostViewController)
        #expect(webView.activeViewportCoordinatorForTesting?.hostViewController === hostViewController)
    }

    @Test
    func managedViewportWebViewPrefersExplicitHostViewControllerOverride() {
        let hostViewController = UIViewController()
        let overrideHostViewController = UIViewController()
        overrideHostViewController.loadViewIfNeeded()

        let navigationController = UINavigationController(rootViewController: hostViewController)
        let window = makeManagedViewportWindow(rootViewController: navigationController)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let webView = ManagedViewportWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        webView.viewportHostViewController = overrideHostViewController
        hostViewController.view.addSubview(webView)
        hostViewController.view.layoutIfNeeded()

        #expect(webView.resolvedHostViewControllerForTesting === overrideHostViewController)
        #expect(webView.activeViewportCoordinatorForTesting?.hostViewController === overrideHostViewController)
    }
}

@MainActor
private func makeManagedViewportWindow(rootViewController: UIViewController) -> UIWindow {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}
#endif

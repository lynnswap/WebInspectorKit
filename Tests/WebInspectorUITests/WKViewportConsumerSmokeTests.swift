#if canImport(UIKit)
import Testing
import UIKit
import WebKit
import WKViewport

@MainActor
struct WKViewportConsumerSmokeTests {
    @Test
    func consumerCanConstructViewportCoordinator() {
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
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)

        coordinator.updateViewport()

        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
        coordinator.invalidate()
    }
}
#endif

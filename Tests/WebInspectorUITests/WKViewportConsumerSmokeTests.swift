#if canImport(UIKit)
import SwiftUI
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

    @Test
    func consumerInstallsObservationViewIntoSwiftUIContainer() async throws {
        let webView = WKWebView(frame: .zero)
        let box = ContainerViewBox()
        let hostingController = UIHostingController(
            rootView: HostingWebViewContainer(webView: webView, box: box)
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostingController.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(10))

        let containerView = try #require(box.view)
        let coordinator = ViewportCoordinator(webView: webView)
        coordinator.updateViewport()

        #expect(hostingController.contentScrollView(for: .top) === webView.scrollView)
        #expect(hostingController.contentScrollView(for: .bottom) === webView.scrollView)
        #expect(containsViewportObservationView(in: containerView))
        #expect(containsViewportObservationView(in: hostingController.view) == false)
        coordinator.invalidate()
    }

    @Test
    func consumerClearsViewportStateWhenDetached() {
        let hostViewController = UIViewController()
        let containerView = UIView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        hostViewController.view.addSubview(containerView)
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: hostViewController.view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: hostViewController.view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: hostViewController.view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: hostViewController.view.bottomAnchor),
        ])

        let webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: containerView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostViewController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let coordinator = ViewportCoordinator(webView: webView)
        coordinator.updateViewport()

        #expect(hostViewController.contentScrollView(for: .top) === webView.scrollView)
        #expect(containsViewportObservationView(in: containerView))

        webView.removeFromSuperview()
        coordinator.updateViewport()

        #expect(hostViewController.contentScrollView(for: .top) == nil)
        #expect(hostViewController.contentScrollView(for: .bottom) == nil)
        #expect(containsViewportObservationView(in: containerView) == false)
        coordinator.invalidate()
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
        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: containerView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private func containsViewportObservationView(in view: UIView?) -> Bool {
    guard let view else {
        return false
    }
    return view.subviews.contains { subview in
        NSStringFromClass(type(of: subview)).contains("ViewportObservationView")
    }
}
#endif

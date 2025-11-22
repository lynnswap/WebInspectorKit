

#if canImport(UIKit)
import SwiftUI
import WebKit

struct WebInspectorTabBarContainer: UIViewControllerRepresentable {
    var model: WebInspectorViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let tabBarController = UITabBarController()
        tabBarController.viewControllers = context.coordinator.controllers
        tabBarController.view.backgroundColor = .clear
        tabBarController.tabBar.scrollEdgeAppearance = tabBarController.tabBar.standardAppearance
        return tabBarController
    }

    func updateUIViewController(_ tabBarController: UITabBarController, context: Context) {}

    @MainActor
    final class Coordinator {
        var controllers: [UIViewController] { [pageController, domHost] }

        private let pageController: WebInspectorPageViewController
        private let domHost: UIHostingController<DOMDetailView>

        init(model: WebInspectorViewModel) {
            pageController = WebInspectorPageViewController(bridge: model.webBridge)
            domHost = UIHostingController(rootView: DOMDetailView(model))
            domHost.view.backgroundColor = .clear
            configureTabItems()
        }

        private func configureTabItems() {
            setTabBarItem(for: .tree, controller: pageController)
            setTabBarItem(for: .detail, controller: domHost)
        }

        private func setTabBarItem(for tab: InspectorTab, controller: UIViewController) {
            controller.tabBarItem = UITabBarItem(
                title: String(localized: tab.title),
                image: UIImage(systemName: tab.systemImage),
                tag: tab.tag
            )
        }
    }
}

private final class WebInspectorPageViewController: UIViewController {
    private var bridge: WebInspectorBridge
    private var webView: WKWebView?

    init(bridge: WebInspectorBridge) {
        self.bridge = bridge
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let webView = bridge.makeInspectorWebView()
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.webView = webView
        view = webView
    }

    @MainActor deinit {
        if let webView {
            bridge.teardownInspectorWebView(webView)
        }
    }
}
#endif



#if canImport(UIKit)
import SwiftUI
import WebKit

struct WITabBarContainer: UIViewControllerRepresentable {
    var model: WIViewModel

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

        private let pageController: WIPageViewController
        private let domHost: UIHostingController<DOMDetailView>

        init(model: WIViewModel) {
            pageController = WIPageViewController(bridge: model.webBridge)
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

private final class WIPageViewController: UIViewController {
    private var bridge: WIBridge
    private var webView: WKWebView?

    init(bridge: WIBridge) {
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

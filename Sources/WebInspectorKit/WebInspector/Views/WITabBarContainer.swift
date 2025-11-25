

#if canImport(UIKit)
import SwiftUI

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
        var controllers: [UIViewController] { [webHost, domHost] }

        private let webHost: UIHostingController<WIDOMView>
        private let domHost: UIHostingController<WIDetailView>

        init(model: WIViewModel) {
            webHost = UIHostingController(rootView: WIDOMView(model))
            webHost.view.backgroundColor = .clear
            domHost = UIHostingController(rootView: WIDetailView(model))
            domHost.view.backgroundColor = .clear
            configureTabItems()
        }

        private func configureTabItems() {
            setTabBarItem(for: .tree, controller: webHost)
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
#endif

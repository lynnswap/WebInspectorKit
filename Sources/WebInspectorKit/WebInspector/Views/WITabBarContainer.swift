#if canImport(UIKit)
import SwiftUI

@available(iOS 18.0, *)
struct WITabBarContainer: UIViewControllerRepresentable {
    var tabs: [InspectorTab]

    func makeCoordinator() -> Coordinator {
        Coordinator(tabs: tabs)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.setTabs(context.coordinator.tabs, animated: false)
        controller.view.backgroundColor = .clear
        controller.tabBar.scrollEdgeAppearance = controller.tabBar.standardAppearance
        return controller
    }

    func updateUIViewController(_ tabBarController: UITabBarController, context: Context) {
    }

    @MainActor
    final class Coordinator {
        let tabs: [UITab]

        init(tabs: [InspectorTab]) {
            self.tabs = tabs.map { tab in
                let host = UIHostingController(rootView: tab.makeContent())
                host.view.backgroundColor = .clear
                return UITab(
                    title: String(localized: tab.title),
                    image: UIImage(systemName: tab.systemImage),
                    identifier: tab.id
                ) { _ in host }
            }
        }
    }
}
#endif

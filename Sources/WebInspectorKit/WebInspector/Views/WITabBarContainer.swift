#if canImport(UIKit)
import SwiftUI

@available(iOS 18.0, *)
struct WITabBarContainer: UIViewControllerRepresentable {
    var tabs: [InspectorTab]
    @Environment(WIViewModel.self) private var model
    
    func makeCoordinator() -> Coordinator {
        Coordinator(model:model,tabs: tabs)
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

        init(model:WIViewModel,tabs: [InspectorTab]) {
            self.tabs = tabs.map { tab in
                let view = tab.makeContent()
                    .environment(model)
                let host = UIHostingController(rootView: view)
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

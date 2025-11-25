#if canImport(UIKit)
import SwiftUI

@available(iOS 18.0, *)
struct WITabBarContainer: UIViewControllerRepresentable {
    var tabs: [WITab]
    @Environment(WebInspectorModel.self) private var model
    
    func makeCoordinator() -> Coordinator {
        Coordinator(model:model,tabs: tabs)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.setTabs(context.coordinator.tabs, animated: false)
        if let selectedTabIdentifier = model.selectedTabIdentifier,
           let selectedTab = context.coordinator.tabs.first(where: { $0.identifier == selectedTabIdentifier }) {
            controller.selectedTab = selectedTab
        }
        controller.view.backgroundColor = .clear
        controller.tabBar.scrollEdgeAppearance = controller.tabBar.standardAppearance
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ tabBarController: UITabBarController, context: Context) {
    }

    @MainActor
    final class Coordinator: NSObject ,UITabBarControllerDelegate{
        private weak var model:WebInspectorModel?
        let tabs: [UITab]

        init(model:WebInspectorModel,tabs: [WITab]) {
            self.model = model
            self.tabs = tabs.map { tab in
                let host = tab.viewController(with: model)
                return UITab(
                    title: String(localized: tab.title),
                    image: UIImage(systemName: tab.systemImage),
                    identifier: tab.id
                ) { _ in host }
            }
        }
        func tabBarController(
            _ tabBarController: UITabBarController,
            didSelectTab selectedTab: UITab,
            previousTab: UITab?
        ) {
            model?.selectedTabIdentifier = selectedTab.identifier
        }
    }
}
#endif

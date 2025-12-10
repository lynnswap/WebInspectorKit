import SwiftUI
#if canImport(UIKit)

struct WITabBarContainer: UIViewControllerRepresentable {
    var model: WebInspectorModel
    var tabs: [WITab]
    
    func makeCoordinator() -> Coordinator {
        Coordinator(model:model,tabs: tabs)
    }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.setTabs(context.coordinator.uiTabs, animated: false)
        
        if let selectedTab = model.selectedTab,
           let selectedUITab = context.coordinator.uiTabs.first(where: { $0.identifier == selectedTab.id }){
            controller.selectedTab = selectedUITab
        }else{
            if let firstTab = context.coordinator.uiTabs.first {
                controller.selectedTab = firstTab
                if let firstWITab = tabs.first(where: {$0.id == firstTab.identifier}){
                    model.selectedTab = firstWITab
                }
            }
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
        let uiTabs: [UITab]
        let wiTabs: [WITab]

        init(model:WebInspectorModel,tabs: [WITab]) {
            self.model = model
            self.wiTabs = tabs
            self.uiTabs = tabs.map { tab in
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
            guard let model else { return }
            let selectedTabIdentifier = selectedTab.identifier
            if let selectedWITab = self.wiTabs.first(where: {$0.id == selectedTabIdentifier}){
                model.selectedTab = selectedWITab
            }
        }
    }
}
#elseif canImport(AppKit)
struct WITabBarContainer: NSViewControllerRepresentable {
    var model: WebInspectorModel
    var tabs: [WITab]

    func makeNSViewController(context: Context) -> WITabViewController {
        let controller = WITabViewController()
        controller.tabStyle = .segmentedControlOnTop
        controller.model = model
        controller.wiTabs = tabs

        controller.tabViewItems = tabs.map { tab in
            let host = tab.viewController(with: model)
            let item = NSTabViewItem(viewController: host)
            item.identifier = tab.id
            item.label = String(localized: tab.title)
            item.image = NSImage(
                systemSymbolName: tab.systemImage,
                accessibilityDescription: nil
            )
            return item
        }

        if let selectedTab = model.selectedTab,
           let index = tabs.firstIndex(where: { $0.id == selectedTab.id }) {
            controller.selectedTabViewItemIndex = index
        } else {
            controller.selectedTabViewItemIndex = 0
            model.selectedTab = tabs.first
        }

        return controller
    }
    func updateNSViewController(_ controller: WITabViewController, context: Context) {
    }
}
final class WITabViewController: NSTabViewController {
    weak var model: WebInspectorModel?
    var wiTabs: [WITab] = []

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)

        guard let id = tabViewItem?.identifier as? String,
              let tab = wiTabs.first(where: { $0.id == id }) else {
            return
        }

        model?.selectedTab = tab
    }
}

#endif

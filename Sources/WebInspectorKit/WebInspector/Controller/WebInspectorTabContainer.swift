import SwiftUI

#if canImport(UIKit)
import UIKit

@MainActor
    struct WebInspectorTabContainer: UIViewControllerRepresentable {
        let controller: WebInspector.Controller
        let tabs: [WebInspector.Tab]

        func makeCoordinator() -> Coordinator {
            Coordinator(controller: controller, tabs: tabs)
        }

        func makeUIViewController(context: Context) -> UITabBarController {
            let tabBarController = UITabBarController()
            tabBarController.setTabs(context.coordinator.uiTabs, animated: false)
            tabBarController.tabBar.scrollEdgeAppearance = tabBarController.tabBar.standardAppearance
            tabBarController.view.backgroundColor = .clear
            tabBarController.delegate = context.coordinator

            syncSelection(into: tabBarController, uiTabs: context.coordinator.uiTabs)
            return tabBarController
        }

        func updateUIViewController(_ tabBarController: UITabBarController, context: Context) {
            context.coordinator.updateTabsIfNeeded(tabs, controller: controller, tabBarController: tabBarController)
            // Keep the native selection in sync with the observable `Controller`.
            syncSelection(into: tabBarController, uiTabs: context.coordinator.uiTabs)
        }

    private func syncSelection(into tabBarController: UITabBarController, uiTabs: [UITab]) {
        let currentSelectedID = tabBarController.selectedTab?.identifier
        let desiredID = controller.selectedTabID

        guard uiTabs.isEmpty == false else {
            tabBarController.selectedTab = nil
            controller.selectedTabID = nil
            return
        }

        if let desiredID {
            if currentSelectedID == desiredID {
                return
            }
            if let tab = uiTabs.first(where: { $0.identifier == desiredID }) {
                tabBarController.selectedTab = tab
                return
            }

            // If the desired ID doesn't exist anymore, fall back to the first tab.
            let first = uiTabs[0]
            tabBarController.selectedTab = first
            controller.selectedTabID = first.identifier
            return
        }

        // No desired selection: keep the current native selection if it exists.
        if let currentSelectedID {
            controller.selectedTabID = currentSelectedID
            return
        }

        // No desired selection and no native selection: select the first tab.
        let first = uiTabs[0]
        tabBarController.selectedTab = first
        controller.selectedTabID = first.identifier
    }

    @MainActor
    final class Coordinator: NSObject, UITabBarControllerDelegate {
        private weak var controller: WebInspector.Controller?
        private var tabIDs: [WebInspector.Tab.ID]
        private(set) var uiTabs: [UITab]

        init(controller: WebInspector.Controller, tabs: [WebInspector.Tab]) {
            self.controller = controller
            self.tabIDs = tabs.map(\.id)
            self.uiTabs = Self.makeUITabs(from: tabs, controller: controller)
        }

        func updateTabsIfNeeded(_ tabs: [WebInspector.Tab], controller: WebInspector.Controller, tabBarController: UITabBarController) {
            self.controller = controller
            let newTabIDs = tabs.map(\.id)
            guard newTabIDs != tabIDs else {
                return
            }
            tabIDs = newTabIDs
            uiTabs = Self.makeUITabs(from: tabs, controller: controller)
            tabBarController.setTabs(uiTabs, animated: false)
        }

        private static func makeUITabs(from tabs: [WebInspector.Tab], controller: WebInspector.Controller) -> [UITab] {
            tabs.map { tab in
                let host = UIHostingController(rootView: tab.view(controller: controller))
                host.view.backgroundColor = .clear
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
            guard let controller else { return }
            controller.selectedTabID = selectedTab.identifier
        }
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
struct WebInspectorTabContainer: NSViewControllerRepresentable {
    let controller: WebInspector.Controller
    let tabs: [WebInspector.Tab]

    func makeNSViewController(context: Context) -> WebInspectorTabViewController {
        let tabController = WebInspectorTabViewController()
        tabController.tabStyle = .segmentedControlOnTop
        tabController.webInspectorController = controller
        tabController.tabs = tabs

        tabController.tabViewItems = tabs.map { tab in
            let host = NSHostingController(rootView: tab.view(controller: controller))
            let item = NSTabViewItem(viewController: host)
            item.identifier = tab.id
            item.label = String(localized: tab.title)
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil)
            return item
        }

        syncSelection(into: tabController)
        return tabController
    }

    func updateNSViewController(_ controller: WebInspectorTabViewController, context: Context) {
        controller.webInspectorController = self.controller
        controller.tabs = tabs
        let currentTabIDs = controller.tabViewItems.compactMap { $0.identifier as? String }
        let newTabIDs = tabs.map(\.id)
        if currentTabIDs != newTabIDs {
            controller.tabViewItems = tabs.map { tab in
                let host = NSHostingController(rootView: tab.view(controller: self.controller))
                let item = NSTabViewItem(viewController: host)
                item.identifier = tab.id
                item.label = String(localized: tab.title)
                item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil)
                return item
            }
        }
        syncSelection(into: controller)
    }

    private func syncSelection(into tabController: WebInspectorTabViewController) {
        guard !tabs.isEmpty else {
            controller.selectedTabID = nil
            return
        }

        let desiredID = controller.selectedTabID
        if let desiredID, let index = tabs.firstIndex(where: { $0.id == desiredID }) {
            if tabController.selectedTabViewItemIndex != index {
                tabController.selectedTabViewItemIndex = index
            }
        } else {
            if tabController.selectedTabViewItemIndex != 0 {
                tabController.selectedTabViewItemIndex = 0
            }
            controller.selectedTabID = tabs[0].id
        }
    }
}

@MainActor
final class WebInspectorTabViewController: NSTabViewController {
    weak var webInspectorController: WebInspector.Controller?
    var tabs: [WebInspector.Tab] = []

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)

        guard let id = tabViewItem?.identifier as? String else {
            return
        }
        webInspectorController?.selectedTabID = id
    }
}

#endif

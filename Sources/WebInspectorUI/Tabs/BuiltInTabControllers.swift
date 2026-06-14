#if canImport(UIKit)
import UIKit

extension WebInspectorTab {
    @MainActor
    package protocol BuiltInController {
        var tabID: WebInspectorTab.ID { get }
        var descriptor: WebInspectorTab.DisplayDescriptor { get }

        func displayItems(for layout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem]
        func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor?
        func contentKeys(
            for layout: WebInspectorTab.HostLayout,
            displayItem: WebInspectorTab.DisplayItem
        ) -> [WebInspectorTab.ContentKey]
        func makeViewController(
            for displayItem: WebInspectorTab.DisplayItem,
            session: WebInspectorSession,
            layout: WebInspectorTab.HostLayout
        ) -> UIViewController
    }
}

extension WebInspectorTab.BuiltInController {
    package func displayItems(for layout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem] {
        [.tab(tabID)]
    }

    package func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor? {
        guard displayItem == .tab(tabID) else {
            return nil
        }
        return descriptor
    }

    package func contentKeys(
        for layout: WebInspectorTab.HostLayout,
        displayItem: WebInspectorTab.DisplayItem
    ) -> [WebInspectorTab.ContentKey] {
        [WebInspectorTab.ContentKey(tabID: tabID, contentID: "root")]
    }
}

extension WebInspectorTab {
    @MainActor
    package struct BuiltInCatalog {
        private let domController = DOMTabController()
        private let networkController = NetworkTabController()

        package init() {}

        package func controller(for tab: WebInspectorTab) -> any WebInspectorTab.BuiltInController {
            controller(for: tab.builtIn)
        }

        package func controller(for builtIn: WebInspectorTab.BuiltIn) -> any WebInspectorTab.BuiltInController {
            switch builtIn {
            case .dom:
                domController
            case .network:
                networkController
            }
        }
    }
}

extension WebInspectorTab {
    @MainActor
    package enum ContentFactory {
        private static let catalog = WebInspectorTab.BuiltInCatalog()

        package static func makeViewController(
            for tab: WebInspectorTab,
            session: WebInspectorSession,
            hostLayout: WebInspectorTab.HostLayout
        ) -> UIViewController {
            makeViewController(
                for: .tab(tab.id),
                session: session,
                hostLayout: hostLayout,
                tabs: session.interface.tabs
            )
        }

        package static func makeViewController(
            for displayItem: WebInspectorTab.DisplayItem,
            session: WebInspectorSession,
            hostLayout: WebInspectorTab.HostLayout
        ) -> UIViewController {
            makeViewController(
                for: displayItem,
                session: session,
                hostLayout: hostLayout,
                tabs: session.interface.tabs
            )
        }

        package static func makeViewController(
            for displayItem: WebInspectorTab.DisplayItem,
            session: WebInspectorSession,
            hostLayout: WebInspectorTab.HostLayout,
            tabs: [WebInspectorTab]
        ) -> UIViewController {
            if case .domElement = displayItem {
                return catalog.controller(for: WebInspectorTab.BuiltIn.dom).makeViewController(
                    for: displayItem,
                    session: session,
                    layout: hostLayout
                )
            }

            guard case let .tab(tabID) = displayItem,
                  let tab = tabs.first(where: { $0.id == tabID }) else {
                return UIViewController()
            }

            return catalog.controller(for: tab).makeViewController(
                for: displayItem,
                session: session,
                layout: hostLayout
            )
        }

        package static func contentKeys(
            for hostLayout: WebInspectorTab.HostLayout,
            displayItem: WebInspectorTab.DisplayItem,
            tabs: [WebInspectorTab]
        ) -> [WebInspectorTab.ContentKey] {
            if case .domElement = displayItem {
                return catalog.controller(for: WebInspectorTab.BuiltIn.dom).contentKeys(
                    for: hostLayout,
                    displayItem: displayItem
                )
            }

            guard case let .tab(tabID) = displayItem,
                  let tab = tabs.first(where: { $0.id == tabID }) else {
                return []
            }

            return catalog.controller(for: tab).contentKeys(
                for: hostLayout,
                displayItem: displayItem
            )
        }
    }
}
#endif

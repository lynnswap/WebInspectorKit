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

        package func controller(for tab: WebInspectorTab) -> (any WebInspectorTab.BuiltInController)? {
            guard let builtIn = tab.builtIn else {
                return nil
            }
            return controller(for: builtIn)
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

            if case let .custom(content) = tab.content {
                let viewController = session.interface.viewController(for: customContentKey(for: tab)) {
                    content.makeViewController(session)
                }
                switch hostLayout {
                case .compact:
                    viewController.webInspectorDetachFromContainerForReuse()
                    return viewController
                case .regular:
                    return RegularSplitRootViewController(contentViewController: viewController)
                }
            }

            guard let controller = catalog.controller(for: tab) else {
                return UIViewController()
            }

            return controller.makeViewController(
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

            guard let controller = catalog.controller(for: tab) else {
                return [customContentKey(for: tab)]
            }

            return controller.contentKeys(
                for: hostLayout,
                displayItem: displayItem
            )
        }

        private static func customContentKey(for tab: WebInspectorTab) -> WebInspectorTab.ContentKey {
            WebInspectorTab.ContentKey(tabID: tab.id, contentID: "root")
        }
    }
}
#endif

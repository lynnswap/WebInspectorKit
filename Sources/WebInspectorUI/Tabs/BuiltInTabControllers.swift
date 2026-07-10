#if canImport(UIKit)
import UIKit
import WebInspectorUIBase

extension WebInspectorTab {
    @MainActor
    package protocol BuiltInController {
        var tabID: WebInspectorTab.ID { get }
        var descriptor: WebInspectorTab.DisplayDescriptor { get }

        func displayItems(for layout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem]
        func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor?
        func makeViewController(
            for displayItem: WebInspectorTab.DisplayItem,
            session: WebInspectorSession,
            contentStore: PresentationContentStore,
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
            contentStore: PresentationContentStore,
            hostLayout: WebInspectorTab.HostLayout
        ) -> UIViewController {
            makeViewController(
                for: .tab(tab.id),
                session: session,
                contentStore: contentStore,
                hostLayout: hostLayout
            )
        }

        package static func makeViewController(
            for displayItem: WebInspectorTab.DisplayItem,
            session: WebInspectorSession,
            contentStore: PresentationContentStore,
            hostLayout: WebInspectorTab.HostLayout
        ) -> UIViewController {
            if case .domElement = displayItem {
                return catalog.controller(for: WebInspectorTab.BuiltIn.dom).makeViewController(
                    for: displayItem,
                    session: session,
                    contentStore: contentStore,
                    layout: hostLayout
                )
            }

            let tabID: WebInspectorTab.ID
            switch displayItem {
            case let .tab(id), let .customTab(id):
                tabID = id
            case .domElement:
                return UIViewController()
            }

            guard let tab = session.interface.tabs.first(where: { $0.id == tabID }) else {
                return UIViewController()
            }

            if case let .custom(content) = tab.content {
                let viewController = contentStore.customViewController(
                    for: customContentKey(for: tab),
                    session: session,
                    makeViewController: content.makeViewController
                )
                switch hostLayout {
                case .compact:
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
                contentStore: contentStore,
                layout: hostLayout
            )
        }

        private static func customContentKey(for tab: WebInspectorTab) -> WebInspectorTab.ContentKey {
            WebInspectorTab.ContentKey(tabID: tab.id, contentID: "root")
        }
    }
}
#endif

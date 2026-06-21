#if canImport(UIKit)
import UIKit

extension WebInspectorTab {
    package enum HostLayout: Hashable {
        case compact
        case regular
    }
}

extension WebInspectorTab {
    package enum DisplayItem: Hashable, Identifiable {
        package typealias ID = String

        case tab(WebInspectorTab.ID)
        case customTab(WebInspectorTab.ID)
        case domElement(parent: WebInspectorTab.ID)

        package static let domElementID: ID = domElementID(parent: "webinspector_dom")

        package static func customTabID(_ tabID: WebInspectorTab.ID) -> ID {
            "webinspector_custom.\(tabID)"
        }

        package static func domElementID(parent: WebInspectorTab.ID) -> ID {
            "\(parent).element"
        }

        package var id: ID {
            switch self {
            case let .tab(tabID):
                tabID
            case let .customTab(tabID):
                Self.customTabID(tabID)
            case let .domElement(parent):
                Self.domElementID(parent: parent)
            }
        }

        package var sourceTabID: WebInspectorTab.ID {
            switch self {
            case let .tab(tabID), let .customTab(tabID), let .domElement(parent: tabID):
                tabID
            }
        }
    }
}

extension WebInspectorTab {
    package struct ContentKey: Hashable {
        package let tabID: WebInspectorTab.ID
        package let contentID: String

        package init(tabID: WebInspectorTab.ID, contentID: String) {
            self.tabID = tabID
            self.contentID = contentID
        }
    }
}

extension WebInspectorTab {
    @MainActor
    package struct DisplayDescriptor {
        package let title: String
        package let image: UIImage?
    }
}

extension WebInspectorTab {
    @MainActor
    package final class ContentCache {
        private var viewControllerByKey: [WebInspectorTab.ContentKey: UIViewController] = [:]

        package func viewController<Content: UIViewController>(
            for key: WebInspectorTab.ContentKey,
            make: () -> Content
        ) -> Content {
            if let cachedViewController = viewControllerByKey[key] {
                if let contentViewController = cachedViewController as? Content {
                    return contentViewController
                }
                cachedViewController.webInspectorDetachFromContainerForReuse()
            }

            let viewController = make()
            viewControllerByKey[key] = viewController
            return viewController
        }

        package func prune(retaining keys: Set<WebInspectorTab.ContentKey>) {
            for (key, viewController) in viewControllerByKey where keys.contains(key) == false {
                viewController.webInspectorDetachFromContainerForReuse()
                viewControllerByKey[key] = nil
            }
        }

        package func removeAll() {
            for viewController in viewControllerByKey.values {
                viewController.webInspectorDetachFromContainerForReuse()
            }
            viewControllerByKey.removeAll()
        }

        #if DEBUG
        package var countForTesting: Int {
            viewControllerByKey.count
        }
        #endif
    }
}

extension WebInspectorTab {
    @MainActor
    package struct DisplayProjection {
        private let catalog = WebInspectorTab.BuiltInCatalog()

        package init() {}

        package func displayItems(
            for hostLayout: WebInspectorTab.HostLayout,
            tabs: [WebInspectorTab]
        ) -> [WebInspectorTab.DisplayItem] {
            tabs.flatMap { tab -> [WebInspectorTab.DisplayItem] in
                guard let controller = catalog.controller(for: tab) else {
                    return [.customTab(tab.id)]
                }
                return controller.displayItems(for: hostLayout)
            }
        }

        package func resolvedSelection(
            for hostLayout: WebInspectorTab.HostLayout,
            tabs: [WebInspectorTab],
            selectedItemID: WebInspectorTab.DisplayItem.ID?
        ) -> WebInspectorTab.DisplayItem? {
            let displayItems = displayItems(for: hostLayout, tabs: tabs)

            if let selectedItemID,
               let selectedDisplayItem = displayItems.first(where: { $0.id == selectedItemID }) {
                return selectedDisplayItem
            }

            if selectedItemID == WebInspectorTab.DisplayItem.domElementID,
               let domItem = displayItems.first(where: { $0 == .tab(WebInspectorTab.dom.id) }) {
                return domItem
            }

            return displayItems.first
        }

        package func descriptor(
            for displayItem: WebInspectorTab.DisplayItem,
            tabs: [WebInspectorTab]
        ) -> WebInspectorTab.DisplayDescriptor? {
            switch displayItem {
            case let .tab(tabID):
                guard let tab = tabs.first(where: { $0.id == tabID }) else {
                    return nil
                }
                guard let controller = catalog.controller(for: tab) else {
                    return WebInspectorTab.DisplayDescriptor(
                        title: tab.title,
                        image: tab.image
                    )
                }
                return controller.descriptor(for: displayItem)
            case let .customTab(tabID):
                guard let tab = tabs.first(where: { $0.id == tabID }),
                      tab.builtIn == nil else {
                    return nil
                }
                return WebInspectorTab.DisplayDescriptor(
                    title: tab.title,
                    image: tab.image
                )
            case .domElement:
                return catalog.controller(for: WebInspectorTab.BuiltIn.dom).descriptor(for: displayItem)
            }
        }

        package func contentKeys(
            for hostLayout: WebInspectorTab.HostLayout,
            tabs: [WebInspectorTab]
        ) -> Set<WebInspectorTab.ContentKey> {
            Set(
                displayItems(for: hostLayout, tabs: tabs).flatMap { displayItem in
                    WebInspectorTab.ContentFactory.contentKeys(
                        for: hostLayout,
                        displayItem: displayItem,
                        tabs: tabs
                    )
                }
            )
        }
    }
}
#endif

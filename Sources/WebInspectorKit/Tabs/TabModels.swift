#if canImport(UIKit)
import UIKit
import WebInspectorUIBase

extension WebInspectorTab {
    enum HostLayout: Hashable {
        case compact
        case regular
    }
}

extension WebInspectorTab {
    enum DisplayItem: Hashable, Identifiable {
        typealias ID = String

        case tab(WebInspectorTab.ID)
        case customTab(WebInspectorTab.ID)
        case domElement(parent: WebInspectorTab.ID)

        static let domElementID: ID = domElementID(parent: "webinspector_dom")

        static func customTabID(_ tabID: WebInspectorTab.ID) -> ID {
            "webinspector_custom.\(tabID)"
        }

        static func domElementID(parent: WebInspectorTab.ID) -> ID {
            "\(parent).element"
        }

        var id: ID {
            switch self {
            case let .tab(tabID):
                tabID
            case let .customTab(tabID):
                Self.customTabID(tabID)
            case let .domElement(parent):
                Self.domElementID(parent: parent)
            }
        }

        var sourceTabID: WebInspectorTab.ID {
            switch self {
            case let .tab(tabID), let .customTab(tabID), let .domElement(parent: tabID):
                tabID
            }
        }
    }
}

extension WebInspectorTab {
    struct ContentKey: Hashable {
        let tabID: WebInspectorTab.ID
        let contentID: String

        init(tabID: WebInspectorTab.ID, contentID: String) {
            self.tabID = tabID
            self.contentID = contentID
        }
    }
}

extension WebInspectorTab {
    @MainActor
    struct DisplayDescriptor {
        let title: String
        let image: UIImage?
    }
}

extension WebInspectorTab {
    @MainActor
    final class ContentCache {
        private var epoch = 0
        private var viewControllerByKey: [WebInspectorTab.ContentKey: UIViewController] = [:]

        func viewController<Content: UIViewController>(
            for key: WebInspectorTab.ContentKey,
            epoch: Int,
            make: () -> Content
        ) -> Content {
            if self.epoch != epoch {
                // Content built for a previous context epoch must never
                // satisfy a lookup from the current one, even when an explicit
                // clear was missed or is still pending.
                removeAll()
                self.epoch = epoch
            }
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

        func prune(retaining keys: Set<WebInspectorTab.ContentKey>) {
            for (key, viewController) in viewControllerByKey where keys.contains(key) == false {
                viewController.webInspectorDetachFromContainerForReuse()
                viewControllerByKey[key] = nil
            }
        }

        func removeAll() {
            for viewController in viewControllerByKey.values {
                viewController.webInspectorDetachFromContainerForReuse()
            }
            viewControllerByKey.removeAll()
        }

        #if DEBUG
        var countForTesting: Int {
            viewControllerByKey.count
        }
        #endif
    }
}

extension WebInspectorTab {
    @MainActor
    struct DisplayProjection {
        private let catalog = WebInspectorTab.BuiltInCatalog()

        init() {}

        func displayItems(
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

        func resolvedSelection(
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

        func descriptor(
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

        func contentKeys(
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

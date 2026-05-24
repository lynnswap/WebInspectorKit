#if canImport(UIKit)
import UIKit

package enum WebInspectorTabHostLayout: Hashable {
    case compact
    case regular
}

package enum TabDisplayItem: Hashable, Identifiable {
    package typealias ID = String

    case tab(WebInspectorTab.ID)
    case domElement(parent: WebInspectorTab.ID)

    package static let domElementID: ID = domElementID(parent: "webinspector_dom")

    package static func domElementID(parent: WebInspectorTab.ID) -> ID {
        "\(parent).element"
    }

    package var id: ID {
        switch self {
        case let .tab(tabID):
            tabID
        case let .domElement(parent):
            Self.domElementID(parent: parent)
        }
    }

    package var sourceTabID: WebInspectorTab.ID {
        switch self {
        case let .tab(tabID), let .domElement(parent: tabID):
            tabID
        }
    }
}

package struct TabContentKey: Hashable {
    package let tabID: WebInspectorTab.ID
    package let contentID: String

    package init(tabID: WebInspectorTab.ID, contentID: String) {
        self.tabID = tabID
        self.contentID = contentID
    }
}

@MainActor
package struct TabDisplayDescriptor {
    package let title: String
    package let image: UIImage?
}

@MainActor
package final class TabContentCache {
    private var viewControllerByKey: [TabContentKey: UIViewController] = [:]

    package func viewController<Content: UIViewController>(
        for key: TabContentKey,
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

    package func prune(retaining keys: Set<TabContentKey>) {
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
}

@MainActor
package struct TabDisplayProjection {
    private let catalog = BuiltInTabCatalog()

    package init() {}

    package func displayItems(
        for hostLayout: WebInspectorTabHostLayout,
        tabs: [WebInspectorTab]
    ) -> [TabDisplayItem] {
        tabs.flatMap { tab in
            catalog.controller(for: tab).displayItems(for: hostLayout)
        }
    }

    package func resolvedSelection(
        for hostLayout: WebInspectorTabHostLayout,
        tabs: [WebInspectorTab],
        selectedItemID: TabDisplayItem.ID?
    ) -> TabDisplayItem? {
        let displayItems = displayItems(for: hostLayout, tabs: tabs)

        if let selectedItemID,
           let selectedDisplayItem = displayItems.first(where: { $0.id == selectedItemID }) {
            return selectedDisplayItem
        }

        if selectedItemID == TabDisplayItem.domElementID,
           let domItem = displayItems.first(where: { $0 == .tab(WebInspectorTab.dom.id) }) {
            return domItem
        }

        return displayItems.first
    }

    package func descriptor(
        for displayItem: TabDisplayItem,
        tabs: [WebInspectorTab]
    ) -> TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return nil
            }
            return catalog.controller(for: tab).descriptor(for: displayItem)
        case .domElement:
            return catalog.controller(for: WebInspectorTab.BuiltIn.dom).descriptor(for: displayItem)
        }
    }

    package func contentKeys(
        for hostLayout: WebInspectorTabHostLayout,
        tabs: [WebInspectorTab]
    ) -> Set<TabContentKey> {
        Set(
            displayItems(for: hostLayout, tabs: tabs).flatMap { displayItem in
                TabContentFactory.contentKeys(
                    for: hostLayout,
                    displayItem: displayItem,
                    tabs: tabs
                )
            }
        )
    }
}
#endif

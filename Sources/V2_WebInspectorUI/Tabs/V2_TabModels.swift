#if canImport(UIKit)
import UIKit

package enum V2_WITabHostLayout: Hashable {
    case compact
    case regular
}

package enum V2_TabDisplayItem: Hashable, Identifiable {
    package typealias ID = String

    case tab(V2_WITab.ID)
    case domElement(parent: V2_WITab.ID)

    package static let domElementID: ID = domElementID(parent: "v2_wi_dom")

    package static func domElementID(parent: V2_WITab.ID) -> ID {
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

    package var sourceTabID: V2_WITab.ID {
        switch self {
        case let .tab(tabID), let .domElement(parent: tabID):
            tabID
        }
    }
}

package struct V2_TabContentKey: Hashable {
    package let tabID: V2_WITab.ID
    package let contentID: String

    package init(tabID: V2_WITab.ID, contentID: String) {
        self.tabID = tabID
        self.contentID = contentID
    }
}

@MainActor
package struct V2_TabDisplayDescriptor {
    package let title: String
    package let image: UIImage?
}

@MainActor
package final class V2_TabContentCache {
    private var viewControllerByKey: [V2_TabContentKey: UIViewController] = [:]

    package func viewController<Content: UIViewController>(
        for key: V2_TabContentKey,
        make: () -> Content
    ) -> Content {
        if let cachedViewController = viewControllerByKey[key] {
            if let contentViewController = cachedViewController as? Content {
                return contentViewController
            }
            cachedViewController.v2WIDetachFromContainerForReuse()
        }

        let viewController = make()
        viewControllerByKey[key] = viewController
        return viewController
    }

    package func prune(retaining keys: Set<V2_TabContentKey>) {
        for (key, viewController) in viewControllerByKey where keys.contains(key) == false {
            viewController.v2WIDetachFromContainerForReuse()
            viewControllerByKey[key] = nil
        }
    }

    package func removeAll() {
        for viewController in viewControllerByKey.values {
            viewController.v2WIDetachFromContainerForReuse()
        }
        viewControllerByKey.removeAll()
    }
}

@MainActor
package struct V2_TabDisplayProjection {
    private let catalog = V2_BuiltInTabCatalog()

    package init() {}

    package func displayItems(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> [V2_TabDisplayItem] {
        tabs.flatMap { tab in
            catalog.controller(for: tab).displayItems(for: hostLayout)
        }
    }

    package func resolvedSelection(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab],
        selectedItemID: V2_TabDisplayItem.ID?
    ) -> V2_TabDisplayItem? {
        let displayItems = displayItems(for: hostLayout, tabs: tabs)

        if let selectedItemID,
           let selectedDisplayItem = displayItems.first(where: { $0.id == selectedItemID }) {
            return selectedDisplayItem
        }

        if selectedItemID == V2_TabDisplayItem.domElementID,
           let domItem = displayItems.first(where: { $0 == .tab(V2_WITab.dom.id) }) {
            return domItem
        }

        return displayItems.first
    }

    package func descriptor(
        for displayItem: V2_TabDisplayItem,
        tabs: [V2_WITab]
    ) -> V2_TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return nil
            }
            return catalog.controller(for: tab).descriptor(for: displayItem)
        case .domElement:
            return catalog.controller(for: V2_WITab.BuiltIn.dom).descriptor(for: displayItem)
        }
    }

    package func contentKeys(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> Set<V2_TabContentKey> {
        Set(
            displayItems(for: hostLayout, tabs: tabs).flatMap { displayItem in
                V2_TabContentFactory.contentKeys(
                    for: hostLayout,
                    displayItem: displayItem,
                    tabs: tabs
                )
            }
        )
    }
}
#endif

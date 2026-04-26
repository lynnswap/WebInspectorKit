#if canImport(UIKit)
import UIKit

@MainActor
struct V2_TabDisplayProjection {
    private let catalog = V2_BuiltInTabCatalog()

    func displayItems(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> [V2_TabDisplayItem] {
        tabs.flatMap { tab in
            catalog.controller(for: tab)?.displayItems(for: hostLayout) ?? [.tab(tab.id)]
        }
    }

    func resolvedSelection(
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

    func descriptor(
        for displayItem: V2_TabDisplayItem,
        tabs: [V2_WITab]
    ) -> V2_TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return nil
            }
            return catalog.controller(for: tab)?.descriptor(for: displayItem)
                ?? V2_TabDisplayDescriptor(title: tab.title, image: tab.image)
        case .domElement:
            return catalog.controller(for: V2_WITab.dom)?.descriptor(for: displayItem)
        }
    }

    func contentKeys(
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

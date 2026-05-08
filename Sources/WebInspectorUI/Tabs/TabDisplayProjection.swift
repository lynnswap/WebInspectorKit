#if canImport(UIKit)
import UIKit

@MainActor
struct TabDisplayProjection {
    private let catalog = BuiltInTabCatalog()

    func displayItems(
        for hostLayout: WITabHostLayout,
        tabs: [WITab]
    ) -> [TabDisplayItem] {
        tabs.flatMap { tab in
            catalog.controller(for: tab)?.displayItems(for: hostLayout) ?? [.tab(tab.id)]
        }
    }

    func resolvedSelection(
        for hostLayout: WITabHostLayout,
        tabs: [WITab],
        selectedItemID: TabDisplayItem.ID?
    ) -> TabDisplayItem? {
        let displayItems = displayItems(for: hostLayout, tabs: tabs)

        if let selectedItemID,
           let selectedDisplayItem = displayItems.first(where: { $0.id == selectedItemID }) {
            return selectedDisplayItem
        }

        if selectedItemID == TabDisplayItem.domElementID,
           let domItem = displayItems.first(where: { $0 == .tab(WITab.dom.id) }) {
            return domItem
        }

        return displayItems.first
    }

    func descriptor(
        for displayItem: TabDisplayItem,
        tabs: [WITab]
    ) -> TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return nil
            }
            return catalog.controller(for: tab)?.descriptor(for: displayItem)
                ?? TabDisplayDescriptor(title: tab.title, image: tab.image)
        case .domElement:
            return catalog.controller(for: WITab.dom)?.descriptor(for: displayItem)
        }
    }

    func contentKeys(
        for hostLayout: WITabHostLayout,
        tabs: [WITab]
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

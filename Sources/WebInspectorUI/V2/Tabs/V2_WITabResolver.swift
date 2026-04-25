#if canImport(UIKit)
import UIKit

@MainActor
struct V2_WITabResolver {
    func displayTabs(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> [V2_WIDisplayTab] {
        tabs.flatMap { tab in
            tab.definition.displayTabs(for: hostLayout, tab: tab)
        }
    }

    func selectedDisplayTab(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab],
        selection: V2_WIDisplayTab.ID?
    ) -> V2_WIDisplayTab? {
        let displayTabs = displayTabs(for: hostLayout, tabs: tabs)

        if let selection,
           let selectedDisplayTab = displayTabs.first(where: { $0.id == selection }) {
            return selectedDisplayTab
        }

        if selection == V2_WIDisplayTab.compactElementID,
           let domTab = displayTabs.first(where: { $0.sourceTab.definition is V2_DOMTabDefinition }) {
            return domTab
        }

        return displayTabs.first
    }

    func contentKeys(
        for hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> Set<V2_WIDisplayContentKey> {
        Set(
            displayTabs(for: hostLayout, tabs: tabs).flatMap { displayTab in
                displayTab.sourceTab.definition.contentKeys(
                    for: hostLayout,
                    displayTab: displayTab
                )
            }
        )
    }
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
enum WIUIKitTabLayoutPolicy {
    static let domTabID = "wi_dom"
    static let elementTabID = "wi_element"

    static func resolveTabs(
        from requestedTabs: [WITabDescriptor],
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) -> [WITabDescriptor] {
        if horizontalSizeClass == .compact {
            return insertingElementTabIfNeeded(into: requestedTabs)
        }

        return removingElementTab(into: requestedTabs)
    }

    static func normalizedSelectedTabID(
        currentSelectedTabID: WITabDescriptor.ID?,
        resolvedTabs: [WITabDescriptor]
    ) -> WITabDescriptor.ID? {
        guard currentSelectedTabID == elementTabID else {
            return currentSelectedTabID
        }

        let hasElementTab = resolvedTabs.contains(where: { $0.id == elementTabID })
        let hasDOMTab = resolvedTabs.contains(where: { $0.id == domTabID })
        guard hasElementTab == false, hasDOMTab else {
            return currentSelectedTabID
        }

        return domTabID
    }

    private static func insertingElementTabIfNeeded(into tabs: [WITabDescriptor]) -> [WITabDescriptor] {
        guard
            let domIndex = tabs.firstIndex(where: { $0.id == domTabID }),
            tabs.contains(where: { $0.id == elementTabID }) == false
        else {
            return tabs
        }

        var resolvedTabs = tabs
        resolvedTabs.insert(.element(), at: domIndex + 1)
        return resolvedTabs
    }

    private static func removingElementTab(into tabs: [WITabDescriptor]) -> [WITabDescriptor] {
        return tabs.filter { $0.id != elementTabID }
    }
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
enum V2_TabContentFactory {
    private static let catalog = V2_BuiltInTabCatalog()
    private static let customController = V2_CustomTabController()

    static func makeViewController(
        for tab: V2_WITab,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: .tab(tab.id),
            session: session,
            hostLayout: hostLayout,
            tabs: session.interface.tabs
        )
    }

    static func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: displayItem,
            session: session,
            hostLayout: hostLayout,
            tabs: session.interface.tabs
        )
    }

    static func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> UIViewController {
        if case .domElement = displayItem {
            return catalog.controller(for: V2_WITab.dom)?.makeViewController(
                for: displayItem,
                session: session,
                layout: hostLayout
            ) ?? UIViewController()
        }

        guard case let .tab(tabID) = displayItem,
              let tab = tabs.first(where: { $0.id == tabID }) else {
            return UIViewController()
        }

        if let controller = catalog.controller(for: tab) {
            return controller.makeViewController(
                for: displayItem,
                session: session,
                layout: hostLayout
            )
        }

        return customController.makeViewController(
            for: tab,
            session: session
        )
    }

    static func contentKeys(
        for hostLayout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem,
        tabs: [V2_WITab]
    ) -> [V2_TabContentKey] {
        if case .domElement = displayItem {
            return catalog.controller(for: V2_WITab.dom)?.contentKeys(
                for: hostLayout,
                displayItem: displayItem
            ) ?? []
        }

        guard case let .tab(tabID) = displayItem,
              let tab = tabs.first(where: { $0.id == tabID }) else {
            return []
        }

        if let controller = catalog.controller(for: tab) {
            return controller.contentKeys(for: hostLayout, displayItem: displayItem)
        }
        return [V2_TabContentKey(tabID: tabID, contentID: "root")]
    }
}
#endif

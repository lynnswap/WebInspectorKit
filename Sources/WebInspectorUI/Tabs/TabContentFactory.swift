#if canImport(UIKit)
import UIKit

@MainActor
enum TabContentFactory {
    private static let catalog = BuiltInTabCatalog()
    private static let customController = CustomTabController()

    static func makeViewController(
        for tab: WITab,
        session: WISession,
        hostLayout: WITabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: .tab(tab.id),
            session: session,
            hostLayout: hostLayout,
            tabs: session.interface.tabs
        )
    }

    static func makeViewController(
        for displayItem: TabDisplayItem,
        session: WISession,
        hostLayout: WITabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: displayItem,
            session: session,
            hostLayout: hostLayout,
            tabs: session.interface.tabs
        )
    }

    static func makeViewController(
        for displayItem: TabDisplayItem,
        session: WISession,
        hostLayout: WITabHostLayout,
        tabs: [WITab]
    ) -> UIViewController {
        if case .domElement = displayItem {
            return catalog.controller(for: WITab.dom)?.makeViewController(
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
        for hostLayout: WITabHostLayout,
        displayItem: TabDisplayItem,
        tabs: [WITab]
    ) -> [TabContentKey] {
        if case .domElement = displayItem {
            return catalog.controller(for: WITab.dom)?.contentKeys(
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
        return [TabContentKey(tabID: tabID, contentID: "root")]
    }
}
#endif

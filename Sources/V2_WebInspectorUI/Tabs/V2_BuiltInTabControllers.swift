#if canImport(UIKit)
import UIKit

@MainActor
package protocol V2_BuiltInTabController {
    var tabID: V2_WITab.ID { get }
    var descriptor: V2_TabDisplayDescriptor { get }

    func displayItems(for layout: V2_WITabHostLayout) -> [V2_TabDisplayItem]
    func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor?
    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem
    ) -> [V2_TabContentKey]
    func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController
}

extension V2_BuiltInTabController {
    package func displayItems(for layout: V2_WITabHostLayout) -> [V2_TabDisplayItem] {
        [.tab(tabID)]
    }

    package func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor? {
        guard displayItem == .tab(tabID) else {
            return nil
        }
        return descriptor
    }

    package func contentKeys(
        for layout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem
    ) -> [V2_TabContentKey] {
        [V2_TabContentKey(tabID: tabID, contentID: "root")]
    }
}

@MainActor
package struct V2_BuiltInTabCatalog {
    private let domController = V2_DOMTabController()
    private let networkController = V2_NetworkTabController()

    package init() {}

    package func controller(for tab: V2_WITab) -> any V2_BuiltInTabController {
        controller(for: tab.builtIn)
    }

    package func controller(for builtIn: V2_WITab.BuiltIn) -> any V2_BuiltInTabController {
        switch builtIn {
        case .dom:
            domController
        case .network:
            networkController
        }
    }
}

@MainActor
package enum V2_TabContentFactory {
    private static let catalog = V2_BuiltInTabCatalog()

    package static func makeViewController(
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

    package static func makeViewController(
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

    package static func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout,
        tabs: [V2_WITab]
    ) -> UIViewController {
        if case .domElement = displayItem {
            return catalog.controller(for: V2_WITab.BuiltIn.dom).makeViewController(
                for: displayItem,
                session: session,
                layout: hostLayout
            )
        }

        guard case let .tab(tabID) = displayItem,
              let tab = tabs.first(where: { $0.id == tabID }) else {
            return UIViewController()
        }

        return catalog.controller(for: tab).makeViewController(
            for: displayItem,
            session: session,
            layout: hostLayout
        )
    }

    package static func contentKeys(
        for hostLayout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem,
        tabs: [V2_WITab]
    ) -> [V2_TabContentKey] {
        if case .domElement = displayItem {
            return catalog.controller(for: V2_WITab.BuiltIn.dom).contentKeys(
                for: hostLayout,
                displayItem: displayItem
            )
        }

        guard case let .tab(tabID) = displayItem,
              let tab = tabs.first(where: { $0.id == tabID }) else {
            return []
        }

        return catalog.controller(for: tab).contentKeys(
            for: hostLayout,
            displayItem: displayItem
        )
    }
}
#endif

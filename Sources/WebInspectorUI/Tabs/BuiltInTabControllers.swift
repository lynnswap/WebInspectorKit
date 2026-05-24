#if canImport(UIKit)
import UIKit

@MainActor
package protocol BuiltInTabController {
    var tabID: WebInspectorTab.ID { get }
    var descriptor: TabDisplayDescriptor { get }

    func displayItems(for layout: WebInspectorTabHostLayout) -> [TabDisplayItem]
    func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor?
    func contentKeys(
        for layout: WebInspectorTabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey]
    func makeViewController(
        for displayItem: TabDisplayItem,
        session: WebInspectorSession,
        layout: WebInspectorTabHostLayout
    ) -> UIViewController
}

extension BuiltInTabController {
    package func displayItems(for layout: WebInspectorTabHostLayout) -> [TabDisplayItem] {
        [.tab(tabID)]
    }

    package func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor? {
        guard displayItem == .tab(tabID) else {
            return nil
        }
        return descriptor
    }

    package func contentKeys(
        for layout: WebInspectorTabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey] {
        [TabContentKey(tabID: tabID, contentID: "root")]
    }
}

@MainActor
package struct BuiltInTabCatalog {
    private let domController = DOMTabController()
    private let networkController = NetworkTabController()

    package init() {}

    package func controller(for tab: WebInspectorTab) -> any BuiltInTabController {
        controller(for: tab.builtIn)
    }

    package func controller(for builtIn: WebInspectorTab.BuiltIn) -> any BuiltInTabController {
        switch builtIn {
        case .dom:
            domController
        case .network:
            networkController
        }
    }
}

@MainActor
package enum TabContentFactory {
    private static let catalog = BuiltInTabCatalog()

    package static func makeViewController(
        for tab: WebInspectorTab,
        session: WebInspectorSession,
        hostLayout: WebInspectorTabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: .tab(tab.id),
            session: session,
            hostLayout: hostLayout,
            tabs: session.interface.tabs
        )
    }

    package static func makeViewController(
        for displayItem: TabDisplayItem,
        session: WebInspectorSession,
        hostLayout: WebInspectorTabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: displayItem,
            session: session,
            hostLayout: hostLayout,
            tabs: session.interface.tabs
        )
    }

    package static func makeViewController(
        for displayItem: TabDisplayItem,
        session: WebInspectorSession,
        hostLayout: WebInspectorTabHostLayout,
        tabs: [WebInspectorTab]
    ) -> UIViewController {
        if case .domElement = displayItem {
            return catalog.controller(for: WebInspectorTab.BuiltIn.dom).makeViewController(
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
        for hostLayout: WebInspectorTabHostLayout,
        displayItem: TabDisplayItem,
        tabs: [WebInspectorTab]
    ) -> [TabContentKey] {
        if case .domElement = displayItem {
            return catalog.controller(for: WebInspectorTab.BuiltIn.dom).contentKeys(
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

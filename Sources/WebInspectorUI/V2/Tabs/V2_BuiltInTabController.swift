#if canImport(UIKit)
import UIKit

@MainActor
protocol V2_BuiltInTabController {
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
    func displayItems(for layout: V2_WITabHostLayout) -> [V2_TabDisplayItem] {
        [.tab(tabID)]
    }

    func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor? {
        guard displayItem == .tab(tabID) else {
            return nil
        }
        return descriptor
    }

    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem
    ) -> [V2_TabContentKey] {
        [V2_TabContentKey(tabID: tabID, contentID: "root")]
    }
}

@MainActor
struct V2_TabDisplayDescriptor {
    let title: String
    let image: UIImage?
}

@MainActor
struct V2_BuiltInTabCatalog {
    private let domController = V2_DOMTabController()
    private let networkController = V2_NetworkTabController()

    func controller(for tab: V2_WITab) -> (any V2_BuiltInTabController)? {
        guard let builtIn = tab.builtIn else {
            return nil
        }
        return controller(for: builtIn)
    }

    func controller(for tabID: V2_WITab.ID) -> (any V2_BuiltInTabController)? {
        switch tabID {
        case V2_WITab.dom.id:
            return domController
        case V2_WITab.network.id:
            return networkController
        default:
            return nil
        }
    }

    private func controller(for builtIn: V2_WITab.BuiltIn) -> any V2_BuiltInTabController {
        switch builtIn {
        case .dom:
            domController
        case .network:
            networkController
        }
    }
}
#endif

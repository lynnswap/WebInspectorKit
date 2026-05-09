#if canImport(UIKit)
import UIKit

@MainActor
protocol BuiltInTabController {
    var tabID: WITab.ID { get }
    var descriptor: TabDisplayDescriptor { get }

    func displayItems(for layout: WITabHostLayout) -> [TabDisplayItem]
    func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor?
    func contentKeys(
        for layout: WITabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey]
    func makeViewController(
        for displayItem: TabDisplayItem,
        session: WISession,
        layout: WITabHostLayout
    ) -> UIViewController
}

extension BuiltInTabController {
    func displayItems(for layout: WITabHostLayout) -> [TabDisplayItem] {
        [.tab(tabID)]
    }

    func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor? {
        guard displayItem == .tab(tabID) else {
            return nil
        }
        return descriptor
    }

    func contentKeys(
        for layout: WITabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey] {
        [TabContentKey(tabID: tabID, contentID: "root")]
    }
}

@MainActor
struct TabDisplayDescriptor {
    let title: String
    let image: UIImage?
}

@MainActor
struct BuiltInTabCatalog {
    private let domController = DOMTabController()
    private let networkController = NetworkTabController()

    func controller(for tab: WITab) -> (any BuiltInTabController)? {
        guard let builtIn = tab.builtIn else {
            return nil
        }
        return controller(for: builtIn)
    }

    func controller(for tabID: WITab.ID) -> (any BuiltInTabController)? {
        switch tabID {
        case WITab.dom.id:
            return domController
        case WITab.network.id:
            return networkController
        default:
            return nil
        }
    }

    private func controller(for builtIn: WITab.BuiltIn) -> any BuiltInTabController {
        switch builtIn {
        case .dom:
            domController
        case .network:
            networkController
        }
    }
}
#endif

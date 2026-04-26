#if canImport(UIKit)
import UIKit

@MainActor
protocol V2_WITabDefinition: AnyObject {
    typealias ID = V2_WITab.ID

    var id: ID { get }
    var title: String { get }
    var image: UIImage? { get }

    func displayTabs(for layout: V2_WITabHostLayout, tab: V2_WITab) -> [V2_WIDisplayTab]
    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayTab: V2_WIDisplayTab
    ) -> [V2_WIDisplayContentKey]
    func makeViewController(
        for displayTab: V2_WIDisplayTab,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController
}

extension V2_WITabDefinition {
    func displayTabs(for layout: V2_WITabHostLayout, tab: V2_WITab) -> [V2_WIDisplayTab] {
        [.content(sourceTab: tab)]
    }

    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayTab: V2_WIDisplayTab
    ) -> [V2_WIDisplayContentKey] {
        [.init(definitionID: id, contentID: "root")]
    }
}
#endif

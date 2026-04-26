#if canImport(UIKit)
import UIKit

@MainActor
enum V2_WIDisplayTabKind: Hashable {
    case content
    case compactElement
}

@MainActor
struct V2_WIDisplayTab: Hashable, Identifiable {
    typealias ID = String

    static let compactElementID = "wi_element"

    let id: ID
    let sourceTab: V2_WITab
    let title: String
    let image: UIImage?
    let kind: V2_WIDisplayTabKind

    static func content(sourceTab: V2_WITab) -> V2_WIDisplayTab {
        V2_WIDisplayTab(
            id: sourceTab.id,
            sourceTab: sourceTab,
            title: sourceTab.title,
            image: sourceTab.image,
            kind: .content
        )
    }

    static func compactElement(sourceTab: V2_WITab) -> V2_WIDisplayTab {
        V2_WIDisplayTab(
            id: compactElementID,
            sourceTab: sourceTab,
            title: "Element",
            image: UIImage(systemName: "info.circle"),
            kind: .compactElement
        )
    }
}
#endif

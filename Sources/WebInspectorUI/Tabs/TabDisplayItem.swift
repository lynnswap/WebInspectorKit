#if canImport(UIKit)
enum TabDisplayItem: Hashable, Identifiable {
    typealias ID = String

    case tab(WITab.ID)
    case domElement(parent: WITab.ID)

    static let domElementID: ID = domElementID(parent: "wi_dom")

    static func domElementID(parent: WITab.ID) -> ID {
        "\(parent).element"
    }

    var id: ID {
        switch self {
        case let .tab(tabID):
            tabID
        case let .domElement(parent):
            Self.domElementID(parent: parent)
        }
    }

    var sourceTabID: WITab.ID {
        switch self {
        case let .tab(tabID), let .domElement(parent: tabID):
            tabID
        }
    }
}
#endif

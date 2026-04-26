#if canImport(UIKit)
enum V2_TabDisplayItem: Hashable, Identifiable {
    typealias ID = String

    case tab(V2_WITab.ID)
    case domElement(parent: V2_WITab.ID)

    static let domElementID: ID = domElementID(parent: "wi_dom")

    static func domElementID(parent: V2_WITab.ID) -> ID {
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

    var sourceTabID: V2_WITab.ID {
        switch self {
        case let .tab(tabID), let .domElement(parent: tabID):
            tabID
        }
    }
}
#endif

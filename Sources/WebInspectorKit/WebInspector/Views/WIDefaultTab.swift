import SwiftUI

enum WIDefaultTab: Int, CaseIterable {
    case dom
    case detail

    var title: LocalizedStringResource {
        switch self {
        case .dom:
            LocalizedStringResource("inspector.tab.dom", bundle: .module)
        case .detail:
            LocalizedStringResource("inspector.tab.detail", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .dom:
            "chevron.left.forwardslash.chevron.right"
        case .detail:
            "info.circle"
        }
    }

    var identifier: String {
        switch self {
        case .dom:
            "wi_dom"
        case .detail:
            "wi_detail"
        }
    }
}
@MainActor
public extension WITab {
    static func dom() -> WITab {
        WITab(
            id: WIDefaultTab.dom.identifier,
            title: WIDefaultTab.dom.title,
            systemImage: WIDefaultTab.dom.systemImage,
            content: {
                WIDOMView()
            }
        )
    }

    static func detail() -> WITab {
        WITab(
            id: WIDefaultTab.detail.identifier,
            title: WIDefaultTab.detail.title,
            systemImage: WIDefaultTab.detail.systemImage,
            content: {
                WIDetailView()
            }
        )
    }
}

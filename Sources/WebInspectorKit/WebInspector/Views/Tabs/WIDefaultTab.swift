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
    static func dom(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            title ?? WIDefaultTab.dom.title,
            systemImage: systemImage ?? WIDefaultTab.dom.systemImage,
            value: WIDefaultTab.dom.identifier,
            role: .inspector,
            content: {
                WIDOMView()
            }
        )
    }

    static func detail(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            title ?? WIDefaultTab.detail.title,
            systemImage: systemImage ?? WIDefaultTab.detail.systemImage,
            value: WIDefaultTab.detail.identifier,
            role: .inspector,
            content: {
                WIDetailView()
            }
        )
    }
}

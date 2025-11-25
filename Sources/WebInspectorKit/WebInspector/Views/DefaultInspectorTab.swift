import SwiftUI

enum DefaultInspectorTab: Int, CaseIterable {
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

public extension InspectorTab {
    static func dom(@ViewBuilder _ content: @escaping (WIViewModel) -> some View) -> InspectorTab {
        InspectorTab(
            id: DefaultInspectorTab.dom.identifier,
            title: DefaultInspectorTab.dom.title,
            systemImage: DefaultInspectorTab.dom.systemImage,
            content: content
        )
    }

    static func detail(@ViewBuilder _ content: @escaping (WIViewModel) -> some View) -> InspectorTab {
        InspectorTab(
            id: DefaultInspectorTab.detail.identifier,
            title: DefaultInspectorTab.detail.title,
            systemImage: DefaultInspectorTab.detail.systemImage,
            content: content
        )
    }
}

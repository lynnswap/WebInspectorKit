import SwiftUI

enum WIDefaultTab: Int, CaseIterable {
    case dom
    case detail
    case network

    var title: LocalizedStringResource {
        switch self {
        case .dom:
            LocalizedStringResource("inspector.tab.dom", bundle: .module)
        case .detail:
            LocalizedStringResource("inspector.tab.detail", bundle: .module)
        case .network:
            LocalizedStringResource("inspector.tab.network", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .dom:
            "chevron.left.forwardslash.chevron.right"
        case .detail:
            "info.circle"
        case .network:
            "waveform.path"
        }
    }

    var identifier: String {
        switch self {
        case .dom:
            "wi_dom"
        case .detail:
            "wi_detail"
        case .network:
            "wi_network"
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

    static func network(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            title ?? WIDefaultTab.network.title,
            systemImage: systemImage ?? WIDefaultTab.network.systemImage,
            value: WIDefaultTab.network.identifier,
            role: .inspector,
            content: {
                WINetworkView()
            }
        )
    }
}

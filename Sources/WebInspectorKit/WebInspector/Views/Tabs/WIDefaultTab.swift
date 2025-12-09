import SwiftUI

enum WIDefaultTab: Int, CaseIterable {
    case dom
    case element
    case network

    var title: LocalizedStringResource {
        switch self {
        case .dom:
            LocalizedStringResource("inspector.tab.dom", bundle: .module)
        case .element:
            LocalizedStringResource("inspector.tab.element", bundle: .module)
        case .network:
            LocalizedStringResource("inspector.tab.network", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .dom:
            "chevron.left.forwardslash.chevron.right"
        case .element:
            "info.circle"
        case .network:
            "waveform.path.ecg.rectangle"
        }
    }

    var identifier: String {
        switch self {
        case .dom:
            "wi_dom"
        case .element:
            "wi_element"
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
            content: { model in
                WIDOMView(viewModel: model.dom)
            }
        )
    }

    static func element(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            title ?? WIDefaultTab.element.title,
            systemImage: systemImage ?? WIDefaultTab.element.systemImage,
            value: WIDefaultTab.element.identifier,
            role: .inspector,
            content: { model in
                WIDOMElementView(viewModel: model.dom)
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
            content: { model in
                WINetworkView(viewModel: model.network)
            }
        )
    }
}

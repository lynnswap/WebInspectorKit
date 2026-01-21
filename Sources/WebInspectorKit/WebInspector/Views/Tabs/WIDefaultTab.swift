import SwiftUI

public enum WIDefaultTab: Int, CaseIterable {
    case dom
    case element
    case network

    public var title: LocalizedStringResource {
        switch self {
        case .dom:
            LocalizedStringResource("inspector.tab.dom", bundle: .module)
        case .element:
            LocalizedStringResource("inspector.tab.element", bundle: .module)
        case .network:
            LocalizedStringResource("inspector.tab.network", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .dom:
            "chevron.left.forwardslash.chevron.right"
        case .element:
            "info.circle"
        case .network:
            "waveform.path.ecg.rectangle"
        }
    }

    public var identifier: String {
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
                NavigationStack{
                    WIDOMView(viewModel: model.dom)
                        .domInspectorToolbar(model, identifier: WIDefaultTab.dom.identifier)
                    
                }
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
                NavigationStack{
                    WIDOMElementView(viewModel: model.dom)
                        .domInspectorToolbar(model, identifier: WIDefaultTab.element.identifier)
                }
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
                @Bindable var network = model.network
                NavigationStack(path: $network.navigationPath) {
                    WINetworkView(viewModel: network)
                        .networkInspectorToolbar(model, identifier: WIDefaultTab.network.identifier)
                }
            }
        )
    }
}

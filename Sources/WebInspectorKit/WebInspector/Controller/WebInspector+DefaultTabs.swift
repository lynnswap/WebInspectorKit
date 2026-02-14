import Observation
import SwiftUI

extension WebInspector.Tab {
    @MainActor
    public static func dom(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WebInspector.Tab {
        WebInspector.Tab(
            title ?? LocalizedStringResource("inspector.tab.dom", bundle: .module),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            id: "wi_dom",
            role: .inspector,
            requires: [.dom],
            activation: .init(domLiveUpdates: true)
        ) { controller in
            NavigationStack {
                WebInspector.DOMTreeView(inspector: controller.dom)
                    .domInspectorToolbar(controller.dom)
            }
        }
    }

    @MainActor
    public static func element(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WebInspector.Tab {
        WebInspector.Tab(
            title ?? LocalizedStringResource("inspector.tab.element", bundle: .module),
            systemImage: systemImage ?? "info.circle",
            id: "wi_element",
            role: .inspector,
            requires: [.dom]
        ) { controller in
            NavigationStack {
                WebInspector.ElementDetailsView(inspector: controller.dom)
                    .domInspectorToolbar(controller.dom)
            }
        }
    }

    @MainActor
    public static func network(
        title: LocalizedStringResource? = nil,
        systemImage: String? = nil
    ) -> WebInspector.Tab {
        WebInspector.Tab(
            title ?? LocalizedStringResource("inspector.tab.network", bundle: .module),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            id: "wi_network",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: true)
        ) { controller in
            @Bindable var network = controller.network
            NavigationStack(path: $network.navigationPath) {
                WebInspector.NetworkView(inspector: network)
            }
        }
    }
}


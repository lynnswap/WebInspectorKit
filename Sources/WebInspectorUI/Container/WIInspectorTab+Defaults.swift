import Foundation
import WebInspectorCore
import WebInspectorResources

extension WIInspectorTab {
    public static func dom(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WIInspectorTab {
        WIInspectorTab(
            panelKind: .domTree,
            title: title ?? wiLocalized("inspector.tab.dom"),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            role: .inspector
        )
    }

#if canImport(UIKit)
    public static func element(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WIInspectorTab {
        WIInspectorTab(
            panelKind: .domDetail,
            title: title ?? wiLocalized("inspector.tab.element"),
            systemImage: systemImage ?? "info.circle",
            role: .inspector
        )
    }
#endif

    public static func network(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WIInspectorTab {
        WIInspectorTab(
            panelKind: .network,
            title: title ?? wiLocalized("inspector.tab.network"),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            role: .inspector
        )
    }
}

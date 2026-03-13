import Foundation
import WebInspectorCore
import WebInspectorResources

extension WITab {
    public static func dom(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            panelKind: .domTree,
            title: title ?? wiLocalized("inspector.tab.dom"),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            role: .builtIn
        )
    }

#if canImport(UIKit)
    public static func element(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            panelKind: .domDetail,
            title: title ?? wiLocalized("inspector.tab.element"),
            systemImage: systemImage ?? "info.circle",
            role: .builtIn
        )
    }
#endif

    public static func network(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            panelKind: .network,
            title: title ?? wiLocalized("inspector.tab.network"),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            role: .builtIn
        )
    }
}

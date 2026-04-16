import Foundation
import WebInspectorRuntime

extension WITab {
    public static func dom(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            id: domTabID,
            title: title ?? wiLocalized("inspector.tab.dom"),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            role: .inspector
        )
    }

#if canImport(UIKit)
    public static func element(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            id: elementTabID,
            title: title ?? wiLocalized("inspector.tab.element"),
            systemImage: systemImage ?? "info.circle",
            role: .inspector
        )
    }
#endif

    public static func network(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            id: networkTabID,
            title: title ?? wiLocalized("inspector.tab.network"),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            role: .inspector
        )
    }

    public static func console(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITab {
        WITab(
            id: consoleTabID,
            title: title ?? wiLocalized("inspector.tab.console", default: "Console"),
            systemImage: systemImage ?? "terminal",
            role: .inspector
        )
    }
}

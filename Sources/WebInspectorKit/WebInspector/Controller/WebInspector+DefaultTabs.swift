import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension WebInspector.TabDescriptor {
    @MainActor
    public static func dom(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WebInspector.TabDescriptor {
        WebInspector.TabDescriptor(
            id: "wi_dom",
            title: title ?? wiLocalized("inspector.tab.dom"),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            role: .inspector,
            requires: [.dom],
            activation: .init(domLiveUpdates: true)
        ) { context in
            #if canImport(UIKit)
            let root = DOMTreeTabViewController(inspector: context.domInspector)
            return UINavigationController(rootViewController: root)
            #elseif canImport(AppKit)
            return DOMTreeTabViewController(inspector: context.domInspector)
            #endif
        }
    }

    @MainActor
    public static func element(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WebInspector.TabDescriptor {
        WebInspector.TabDescriptor(
            id: "wi_element",
            title: title ?? wiLocalized("inspector.tab.element"),
            systemImage: systemImage ?? "info.circle",
            role: .inspector,
            requires: [.dom]
        ) { context in
            #if canImport(UIKit)
            let root = ElementDetailsTabViewController(inspector: context.domInspector)
            return UINavigationController(rootViewController: root)
            #elseif canImport(AppKit)
            return ElementDetailsTabViewController(inspector: context.domInspector)
            #endif
        }
    }

    @MainActor
    public static func network(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WebInspector.TabDescriptor {
        WebInspector.TabDescriptor(
            id: "wi_network",
            title: title ?? wiLocalized("inspector.tab.network"),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: true)
        ) { context in
            #if canImport(UIKit)
            return NetworkTabViewController(inspector: context.networkInspector)
            #elseif canImport(AppKit)
            return NetworkTabViewController(inspector: context.networkInspector)
            #endif
        }
    }
}

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension WITabDescriptor {
    @MainActor
    public static func dom(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITabDescriptor {
        WITabDescriptor(
            id: "wi_dom",
            title: title ?? wiLocalized("inspector.tab.dom"),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            role: .inspector,
            requires: [.dom],
            activation: .init(domLiveUpdates: true)
        ) { context in
            #if canImport(UIKit)
            if context.horizontalSizeClass == .compact {
                return DOMTreeTabViewController(inspector: context.domInspector)
            }
            return DOMInspectorTabViewController(inspector: context.domInspector)
            #elseif canImport(AppKit)
            return DOMInspectorTabViewController(inspector: context.domInspector)
            #endif
        }
    }
    #if canImport(UIKit)
    @MainActor
    public static func element(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITabDescriptor {
        WITabDescriptor(
            id: "wi_element",
            title: title ?? wiLocalized("inspector.tab.element"),
            systemImage: systemImage ?? "info.circle",
            role: .inspector,
            requires: [.dom]
        ) { context in
            ElementDetailsTabViewController(inspector: context.domInspector)
        }
    }
    #endif
    @MainActor
    public static func network(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WITabDescriptor {
        WITabDescriptor(
            id: "wi_network",
            title: title ?? wiLocalized("inspector.tab.network"),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: true)
        ) { context in
            #if canImport(UIKit)
            let vc: UIViewController
            if context.horizontalSizeClass == .compact {
                vc = NetworkCompactTabViewController(inspector: context.networkInspector)
            } else {
                vc = NetworkTabViewController(inspector: context.networkInspector)
            }
            vc.view.backgroundColor = .clear
            return vc
            #elseif canImport(AppKit)
            return NetworkTabViewController(inspector: context.networkInspector)
            #endif
        }
    }
}

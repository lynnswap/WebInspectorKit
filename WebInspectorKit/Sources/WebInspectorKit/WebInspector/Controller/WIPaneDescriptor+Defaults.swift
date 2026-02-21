import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension WIPaneDescriptor {
    @MainActor
    public static func dom(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WIPaneDescriptor {
        WIPaneDescriptor(
            id: "wi_dom",
            title: title ?? wiLocalized("inspector.tab.dom"),
            systemImage: systemImage ?? "chevron.left.forwardslash.chevron.right",
            role: .inspector,
            requires: [.dom],
            activation: .init(domLiveUpdates: true)
        ) { context in
            #if canImport(UIKit)
            let root = DOMTreeTabViewController(inspector: context.domInspector)
            let nc = UINavigationController(rootViewController: root)
            wiApplyClearNavigationBarStyle(to: nc)
            return nc
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
    ) -> WIPaneDescriptor {
        WIPaneDescriptor(
            id: "wi_element",
            title: title ?? wiLocalized("inspector.tab.element"),
            systemImage: systemImage ?? "info.circle",
            role: .inspector,
            requires: [.dom]
        ) { context in
            let root = ElementDetailsTabViewController(inspector: context.domInspector)
            let nc = UINavigationController(rootViewController: root)
            wiApplyClearNavigationBarStyle(to: nc)
            return nc
        }
    }
    #endif
    @MainActor
    public static func network(
        title: String? = nil,
        systemImage: String? = nil
    ) -> WIPaneDescriptor {
        WIPaneDescriptor(
            id: "wi_network",
            title: title ?? wiLocalized("inspector.tab.network"),
            systemImage: systemImage ?? "waveform.path.ecg.rectangle",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: true)
        ) { context in
            #if canImport(UIKit)
            let vc = NetworkTabViewController(inspector: context.networkInspector)
            vc.view.backgroundColor = .clear
            return vc
            #elseif canImport(AppKit)
            return NetworkTabViewController(inspector: context.networkInspector)
            #endif
        }
    }
}

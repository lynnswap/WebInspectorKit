#if canImport(UIKit)
import UIKit

@MainActor
public enum V2_WIStandardTab: String, CaseIterable, Hashable {
    case dom = "wi_dom"
    case network = "wi_network"

    var id: V2_WITab.ID {
        rawValue
    }

    var title: String {
        switch self {
        case .dom:
            "DOM"
        case .network:
            "Network"
        }
    }

    var image: UIImage? {
        switch self {
        case .dom:
            UIImage(systemName: "chevron.left.forwardslash.chevron.right")
        case .network:
            UIImage(systemName: "waveform.path.ecg.rectangle")
        }
    }
}

extension V2_WITab {
    public static var dom: V2_WITab {
        V2_WITab(definition: V2_DOMTabDefinition())
    }

    public static var network: V2_WITab {
        V2_WITab(definition: V2_NetworkTabDefinition())
    }

    public static var defaults: [V2_WITab] {
        [.dom, .network]
    }
}
#endif

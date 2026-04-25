#if canImport(UIKit)
import UIKit

@MainActor
enum V2_WIStandardTab: String, CaseIterable {
    case dom
    case network

    init?(id: V2_WITab.ID) {
        self.init(rawValue: id)
    }

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

    var tab: V2_WITab {
        V2_WITab(
            title: title,
            image: image,
            identifier: id
        )
    }
}

extension V2_WITab {
    public static var dom: V2_WITab {
        V2_WIStandardTab.dom.tab
    }

    public static var network: V2_WITab {
        V2_WIStandardTab.network.tab
    }

    public static var defaults: [V2_WITab] {
        [.dom, .network]
    }
}
#endif

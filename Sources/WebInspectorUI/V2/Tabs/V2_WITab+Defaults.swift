#if canImport(UIKit)
import UIKit

extension V2_WITab {
    public static var dom: V2_WITab {
        V2_WITab(
            title: "DOM",
            image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
            identifier: "dom",
            viewControllerProvider: { _, session in
                V2_DOMTabViewController(session: session)
            }
        )
    }

    public static var network: V2_WITab {
        V2_WITab(
            title: "Network",
            image: UIImage(systemName: "waveform.path.ecg.rectangle"),
            identifier: "network",
            viewControllerProvider: { _, _ in
                V2_NetworkSplitViewController()
            }
        )
    }

    public static var defaults: [V2_WITab] {
        [.dom, .network]
    }
}
#endif

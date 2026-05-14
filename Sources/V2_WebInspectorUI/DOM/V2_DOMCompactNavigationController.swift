#if canImport(UIKit)
import UIKit

@MainActor
package final class V2_DOMCompactNavigationController: UINavigationController {
    package override init(rootViewController: UIViewController) {
        rootViewController.v2WIDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        v2WIApplyClearNavigationBarStyle(to: self)
        rootViewController.navigationItem.style = .browser
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 DOM Compact Tree") {
    V2_DOMCompactNavigationController(
        rootViewController: V2_DOMTreeViewController(dom: V2_DOMPreviewFixtures.makeDOMSession())
    )
}

#Preview("V2 DOM Compact Element") {
    V2_DOMCompactNavigationController(
        rootViewController: V2_DOMElementViewController(dom: V2_DOMPreviewFixtures.makeDOMSession())
    )
}
#endif
#endif

#if canImport(UIKit)
import UIKit
import V2_WebInspectorRuntime

@MainActor
package final class V2_DOMCompactNavigationController: UINavigationController {
    private var domNavigationItems: V2_DOMNavigationItems?

    package override init(rootViewController: UIViewController) {
        rootViewController.v2WIDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        v2WIApplyClearNavigationBarStyle(to: self)
        rootViewController.navigationItem.style = .browser
    }

    package init(
        rootViewController: UIViewController,
        session: V2_InspectorSession
    ) {
        rootViewController.v2WIDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        v2WIApplyClearNavigationBarStyle(to: self)
        rootViewController.navigationItem.style = .browser
        let navigationItems = V2_DOMNavigationItems(session: session)
        navigationItems.install(on: rootViewController.navigationItem) { [weak self] in
            self?.undoManager
        }
        domNavigationItems = navigationItems
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

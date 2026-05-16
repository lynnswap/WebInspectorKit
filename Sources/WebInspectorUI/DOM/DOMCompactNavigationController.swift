#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
package final class DOMCompactNavigationController: UINavigationController {
    private var domNavigationItems: DOMNavigationItems?

    package override init(rootViewController: UIViewController) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        webInspectorApplyClearNavigationBarStyle(to: self)
        rootViewController.navigationItem.style = .browser
    }

    package init(
        rootViewController: UIViewController,
        session: InspectorSession
    ) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        webInspectorApplyClearNavigationBarStyle(to: self)
        rootViewController.navigationItem.style = .browser
        let treeViewController = rootViewController as? DOMTreeViewController
        let navigationItems = DOMNavigationItems(session: session)
        navigationItems.install(on: rootViewController.navigationItem) { [weak self, weak treeViewController] in
            treeViewController?.domTreeUndoManager ?? self?.undoManager
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

#Preview("DOM Compact Tree") {
    DOMCompactNavigationController(
        rootViewController: DOMTreeViewController(dom: DOMPreviewFixtures.makeDOMSession())
    )
}

#Preview("DOM Compact Element") {
    DOMCompactNavigationController(
        rootViewController: DOMElementViewController(dom: DOMPreviewFixtures.makeDOMSession())
    )
}
#endif
#endif

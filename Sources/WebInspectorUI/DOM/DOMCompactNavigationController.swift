#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
package final class DOMCompactNavigationController: UINavigationController {
    private var domNavigationItems: DOMNavigationItems?

    package override init(rootViewController: UIViewController) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = false
        webInspectorApplyNavigationControllerBackground(to: self)
        rootViewController.navigationItem.style = .browser
    }

    package init(
        rootViewController: UIViewController,
        session: InspectorSession
    ) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = false
        webInspectorApplyNavigationControllerBackground(to: self)
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

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        registerForTraitChanges([WebInspectorDrawsBackgroundTrait.self]) { (self: Self, _) in
            self.applyBackgroundFromTraits()
        }
    }

    private func applyBackgroundFromTraits() {
        webInspectorApplyNavigationControllerBackground(to: self)
    }
}

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

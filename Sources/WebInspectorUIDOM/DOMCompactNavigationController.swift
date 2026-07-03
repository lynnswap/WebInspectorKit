#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

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
        context: WebInspectorContext
    ) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = false
        webInspectorApplyNavigationControllerBackground(to: self)
        rootViewController.navigationItem.style = .browser
        let treeViewController = rootViewController as? DOMTreeViewController
        let navigationItems = DOMNavigationItems(context: context)
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
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { navigationController in
                navigationController.applyBackgroundFromTraits()
            }
        }
    }

    private func applyBackgroundFromTraits() {
        webInspectorApplyNavigationControllerBackground(to: self)
    }
}

#if DEBUG
extension DOMCompactNavigationController {
    var domNavigationItemsForTesting: DOMNavigationItems? {
        domNavigationItems
    }
}
#endif

#Preview("DOM Compact Tree") {
    DOMCompactNavigationController(
        rootViewController: DOMTreeViewController(context: DOMPreviewFixtures.makeWebInspectorContext())
    )
}

#Preview("DOM Compact Element") {
    DOMCompactNavigationController(
        rootViewController: DOMElementViewController(context: DOMPreviewFixtures.makeWebInspectorContext())
    )
}
#endif

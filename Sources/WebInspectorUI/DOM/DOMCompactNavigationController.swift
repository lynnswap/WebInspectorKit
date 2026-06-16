#if canImport(UIKit)
import WebInspectorCore
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
        inspector: InspectorSession
    ) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = false
        webInspectorApplyNavigationControllerBackground(to: self)
        rootViewController.navigationItem.style = .browser
        let treeViewController = rootViewController as? DOMTreeViewController
        let navigationItems = DOMNavigationItems(inspector: inspector)
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
        rootViewController: DOMTreeViewController(dom: DOMPreviewFixtures.makeDOMSession())
    )
}

#Preview("DOM Compact Element") {
    let inspection = AttachedInspection(dom: DOMPreviewFixtures.makeDOMSession())
    DOMCompactNavigationController(
        rootViewController: DOMElementViewController(inspection: inspection)
    )
}
#endif

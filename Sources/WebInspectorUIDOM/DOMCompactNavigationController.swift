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
        model: DOMPanelModel
    ) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        navigationBar.prefersLargeTitles = false
        webInspectorApplyNavigationControllerBackground(to: self)
        rootViewController.navigationItem.style = .browser
        let treeViewController = rootViewController as? DOMTreeViewController
        let navigationItems = DOMNavigationItems(model: model)
        navigationItems.install(on: rootViewController.navigationItem) { [weak self, weak treeViewController] in
            treeViewController?.domTreeUndoManager ?? self?.undoManager
        }
        domNavigationItems = navigationItems
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package var canBecomeFirstResponder: Bool {
        domNavigationItems != nil
    }

    override package var keyCommands: [UIKeyCommand]? {
        domNavigationItems?.makeKeyCommands(actions: DOMNavigationItems.KeyCommandActions(
            undo: #selector(performDOMUndoCommand),
            redo: #selector(performDOMRedoCommand),
            reload: #selector(performDOMReloadCommand),
            delete: #selector(performDOMDeleteCommand),
            pickElement: #selector(performDOMPickElementCommand)
        ))
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

    @objc
    private func performDOMUndoCommand(_ sender: UIKeyCommand) {
        domNavigationItems?.performUndoCommand()
    }

    @objc
    private func performDOMRedoCommand(_ sender: UIKeyCommand) {
        domNavigationItems?.performRedoCommand()
    }

    @objc
    private func performDOMReloadCommand(_ sender: UIKeyCommand) {
        domNavigationItems?.performReloadCommand()
    }

    @objc
    private func performDOMDeleteCommand(_ sender: UIKeyCommand) {
        domNavigationItems?.performDeleteCommand()
    }

    @objc
    private func performDOMPickElementCommand(_ sender: UIKeyCommand) {
        domNavigationItems?.performToggleElementPickerCommand()
    }
}

#if DEBUG
extension DOMCompactNavigationController {
    var domNavigationItemsForTesting: DOMNavigationItems? {
        domNavigationItems
    }
}
#endif

#endif

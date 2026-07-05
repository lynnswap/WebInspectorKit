#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
package final class DOMSplitViewController: UISplitViewController {
    private let treeViewController: DOMTreeViewController
    private let elementViewController: DOMElementViewController
    private let context: WebInspectorContext?
    private var domNavigationItems: DOMNavigationItems?
    private lazy var treeNavigationController = RegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementNavigationController = RegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    package convenience init(context: WebInspectorContext) {
        self.init(
            treeViewController: DOMTreeViewController(context: context),
            elementViewController: DOMElementViewController(context: context),
            context: context
        )
    }

    package init(
        treeViewController: DOMTreeViewController,
        elementViewController: DOMElementViewController,
        context: WebInspectorContext? = nil
    ) {
        self.treeViewController = treeViewController
        self.elementViewController = elementViewController
        self.context = context
        super.init(style: .doubleColumn)
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
            webInspectorRegisterForBackgroundTraitChanges { splitViewController in
                splitViewController.applyBackgroundFromTraits()
            }
        }
        configureSplitViewLayout()
        configureNavigationItem()
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        if #available(iOS 26.0, *) {
            preferredDisplayMode = .secondaryOnly
            setViewController(treeNavigationController, for: .secondary)
            setViewController(elementNavigationController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
            show(.inspector)
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(treeNavigationController, for: .primary)
            setViewController(elementNavigationController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }

    private func configureNavigationItem() {
        guard let context else {
            return
        }
        let navigationItems = DOMNavigationItems(context: context)
        navigationItems.install(on: navigationItem) { [weak self] in
            self?.treeViewController.domTreeUndoManager ?? self?.undoManager
        }
        domNavigationItems = navigationItems
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
extension DOMSplitViewController {
    var domNavigationItemsForTesting: DOMNavigationItems? {
        domNavigationItems
    }
}
#endif

#Preview("DOM Split") {
    DOMSplitViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMSplitViewControllerPreview {
    static func makeViewController() -> DOMSplitViewController {
        DOMSplitViewController(context: DOMPreviewFixtures.makeWebInspectorContext())
    }
}
#endif

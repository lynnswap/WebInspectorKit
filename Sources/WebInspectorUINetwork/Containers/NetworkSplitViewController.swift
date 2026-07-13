#if canImport(UIKit)
import WebInspectorUIBase
import UIKit

@MainActor
package final class NetworkSplitViewController: UISplitViewController {
    private let primaryViewController: NetworkListColumnNavigationController
    private let secondaryViewController: RegularSplitColumnNavigationController

    package init(
        model: NetworkPanelModel,
        listViewController: NetworkListViewController,
        detailViewController: NetworkDetailViewController
    ) {
        primaryViewController = NetworkListColumnNavigationController(
            rootViewController: listViewController
        )
        secondaryViewController = RegularSplitColumnNavigationController(
            rootViewController: detailViewController,
            hidesNavigationBar: false
        )
        super.init(style: .doubleColumn)
        listViewController.setEntrySelectionAction { [weak model] entryID in
            model?.selectEntry(entryID)
        }
        configureSplitViewLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { splitViewController in
                splitViewController.applyBackgroundFromTraits()
            }
        }
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary
        preferredPrimaryColumnWidthFraction = 0.33

        setViewController(primaryViewController, for: .primary)
        setViewController(secondaryViewController, for: .secondary)
    }

}

@MainActor
private final class NetworkListColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        webInspectorApplyNavigationControllerBackground(to: self)
        navigationBar.prefersLargeTitles = false
        setNavigationBarHidden(false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(false, animated: false)
    }

    override func viewDidLoad() {
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

#endif

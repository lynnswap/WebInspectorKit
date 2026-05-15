#if canImport(UIKit)
import UIKit

@MainActor
package final class NetworkSplitViewController: UISplitViewController {
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController
    private let primaryViewController: NetworkListColumnNavigationController
    private let secondaryViewController: RegularSplitColumnNavigationController

    package init(
        model: NetworkPanelModel,
        listViewController: NetworkListViewController,
        detailViewController: NetworkDetailViewController
    ) {
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        primaryViewController = NetworkListColumnNavigationController(
            rootViewController: listViewController
        )
        secondaryViewController = RegularSplitColumnNavigationController(
            rootViewController: detailViewController
        )
        super.init(style: .doubleColumn)
        listViewController.setRequestSelectionAction { [weak model] request in
            model?.selectRequest(request)
        }
        configureSplitViewLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureNavigationItem()
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

    private func configureNavigationItem() {
        let item = detailViewController.makeRegularModeItem()
        if #available(iOS 26.0, *) {
            item.hidesSharedBackground = true
        }
        let group = UIBarButtonItemGroup(
            barButtonItems: [item],
            representativeItem: nil
        )
        navigationItem.trailingItemGroups = [
            group,
        ]
    }
}

@MainActor
private final class NetworkListColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        webInspectorApplyClearNavigationBarStyle(to: self)
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
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("Network Split") {
    let model = NetworkPreviewFixtures.makePanelModel(mode: .detail)
    NetworkSplitViewController(
        model: model,
        listViewController: NetworkListViewController(
            model: model
        ),
        detailViewController: NetworkDetailViewController(
            model: model
        )
    )
}
#endif
#endif

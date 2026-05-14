#if canImport(UIKit)
import UIKit

@MainActor
package final class V2_NetworkSplitViewController: UISplitViewController {
    private let listViewController: V2_NetworkListViewController
    private let detailViewController: V2_NetworkDetailViewController
    private let primaryViewController: V2_NetworkListColumnNavigationController
    private let secondaryViewController: V2_RegularSplitColumnNavigationController

    package init(
        model: V2_NetworkPanelModel,
        listViewController: V2_NetworkListViewController,
        detailViewController: V2_NetworkDetailViewController
    ) {
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        primaryViewController = V2_NetworkListColumnNavigationController(
            rootViewController: listViewController
        )
        secondaryViewController = V2_RegularSplitColumnNavigationController(
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
private final class V2_NetworkListColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.v2WIDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        v2WIApplyClearNavigationBarStyle(to: self)
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

#Preview("V2 Network Split") {
    let model = V2_NetworkPreviewFixtures.makePanelModel(mode: .detail)
    V2_NetworkSplitViewController(
        model: model,
        listViewController: V2_NetworkListViewController(
            model: model
        ),
        detailViewController: V2_NetworkDetailViewController(
            model: model
        )
    )
}
#endif
#endif

import Foundation
import WebInspectorCore

#if canImport(UIKit)
import UIKit

@MainActor
final class WINetworkRegularSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let store: WINetworkStore

    private let listPaneViewController: WINetworkListViewController
    private let listNavigationController: UINavigationController
    private let detailViewController: WINetworkDetailViewController
    private let detailNavigationController: UINavigationController

    init(store: WINetworkStore, queryModel: WINetworkQueryState) {
        self.store = store
        let listPaneViewController = WINetworkListViewController(store: store, queryModel: queryModel)
        self.listPaneViewController = listPaneViewController
        let listNavigationController = UINavigationController(rootViewController: listPaneViewController)
        wiApplyClearNavigationBarStyle(to: listNavigationController)
        listNavigationController.navigationBar.prefersLargeTitles = false
        self.listNavigationController = listNavigationController
        let detailViewController = WINetworkDetailViewController(
            store: store,
            showsNavigationControls: false
        )
        self.detailViewController = detailViewController
        let detailNavigationController = UINavigationController(rootViewController: detailViewController)
        wiApplyClearNavigationBarStyle(to: detailNavigationController)
        detailNavigationController.setNavigationBarHidden(true, animated: false)
        self.detailNavigationController = detailNavigationController

        super.init(style: .doubleColumn)

        delegate = self
        title = nil
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(listNavigationController, for: .primary)
        setViewController(detailNavigationController, for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
        updateNavigationItemState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
        updateNavigationItemState()
    }

    private func updateNavigationItemState() {
        applyNavigationItemState(to: navigationItem)
        if let hostNavigationItem = parent?.navigationItem {
            applyNavigationItemState(to: hostNavigationItem)
        }
    }

    private func applyNavigationItemState(to navigationItem: UINavigationItem) {
        navigationItem.searchController = nil
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems([listPaneViewController.filterNavigationItem], animated: false)
        navigationItem.additionalOverflowItems = listPaneViewController.hostOverflowItemsForRegularNavigation
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        if store.selectedEntry == nil {
            return .primary
        }
        return proposedTopColumn
    }
}
#endif

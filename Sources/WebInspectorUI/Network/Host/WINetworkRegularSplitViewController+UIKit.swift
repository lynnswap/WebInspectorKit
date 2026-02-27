import Foundation
import ObservationsCompat
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
final class WINetworkRegularSplitViewController: UISplitViewController, UISplitViewControllerDelegate, WIHostNavigationItemProvider {
    private let inspector: WINetworkModel
    private var hasStartedObservingInspector = false
    private let selectionUpdateCoalescer = UIUpdateCoalescer()

    private let listPaneViewController: WINetworkListViewController
    private let listNavigationController: UINavigationController
    private let detailViewController: WINetworkDetailViewController
    private let detailNavigationController: UINavigationController
    let hostNavigationState = WIHostNavigationState()

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        let listPaneViewController = WINetworkListViewController(inspector: inspector, queryModel: queryModel)
        self.listPaneViewController = listPaneViewController
        let listNavigationController = UINavigationController(rootViewController: listPaneViewController)
        wiApplyClearNavigationBarStyle(to: listNavigationController)
        listNavigationController.navigationBar.prefersLargeTitles = false
        self.listNavigationController = listNavigationController
        let detailViewController = WINetworkDetailViewController(
            inspector: inspector,
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
        startObservingInspectorIfNeeded()
        updateHostNavigationState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showPrimaryColumnIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        listPaneViewController.applyListColumnNavigationItemsForRegularLayout()
        updateHostNavigationState()
        syncDetailSelection()
    }

    private func startObservingInspectorIfNeeded() {
        guard hasStartedObservingInspector == false else {
            return
        }
        hasStartedObservingInspector = true

        inspector.observeTask(
            [
                \.selectedEntry
            ]
        ) { [weak self] in
            self?.scheduleDetailSelectionSync()
        }
        inspector.store.observeTask(
            [
                \.entries
            ]
        ) { [weak self] in
            self?.scheduleDetailSelectionSync()
        }
    }

    private func scheduleDetailSelectionSync() {
        selectionUpdateCoalescer.schedule { [weak self] in
            self?.syncDetailSelection()
        }
    }

    private func syncDetailSelection() {
        let selectedEntry = inspector.revalidateSelectedEntryAgainstStore()
        detailViewController.display(selectedEntry, hasEntries: !inspector.store.entries.isEmpty)
        listPaneViewController.selectEntry(with: selectedEntry?.id)

        if selectedEntry == nil {
            showPrimaryColumnIfNeeded()
        }
    }

    private func showPrimaryColumnIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            return
        }
        guard viewController(for: .primary) != nil else {
            return
        }
        show(.primary)
    }

    private func updateHostNavigationState() {
        hostNavigationState.searchController = nil
        hostNavigationState.preferredSearchBarPlacement = nil
        hostNavigationState.hidesSearchBarWhenScrolling = false
        hostNavigationState.leftBarButtonItems = nil
        hostNavigationState.rightBarButtonItems = [listPaneViewController.filterNavigationItem]
        hostNavigationState.additionalOverflowItems = listPaneViewController.hostOverflowItemsForRegularNavigation
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        if inspector.selectedEntry == nil {
            return .primary
        }
        return proposedTopColumn
    }
}
#endif

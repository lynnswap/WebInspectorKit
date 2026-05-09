#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class NetworkSplitViewController: UISplitViewController {
    private let inspector: WINetworkModel
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkEntryDetailViewController
    private let primaryViewController: NetworkListColumnNavigationController
    private let secondaryViewController: WIRegularSplitColumnNavigationController

    init(
        inspector: WINetworkModel,
        listViewController: NetworkListViewController,
        detailViewController: NetworkEntryDetailViewController
    ) {
        self.inspector = inspector
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        primaryViewController = NetworkListColumnNavigationController(
            rootViewController: listViewController
        )
        secondaryViewController = WIRegularSplitColumnNavigationController(
            rootViewController: detailViewController
        )
        super.init(style: .doubleColumn)
        listViewController.setEntrySelectionAction { [weak self] entry in
            self?.showEntryDetail(entry)
        }
        configureSplitViewLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
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

    private func showEntryDetail(_ entry: NetworkEntry?) {
        inspector.selectEntry(entry)
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
            group
        ]
    }
}

@MainActor
private final class NetworkListColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.wiDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        wiApplyClearNavigationBarStyle(to: self)
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
import WebInspectorRuntime

#Preview("Network Split") {
    let network = WebInspectorRuntime.WINetworkRuntime()
    NetworkSplitViewController(
        inspector: network.model,
        listViewController: NetworkListViewController(inspector: network.model),
        detailViewController: NetworkEntryDetailViewController(inspector: network.model)
    )
}

#Preview("Network Split Entries") {
    let inspector = WINetworkPreviewFixtures.makeInspector(mode: .detail)
    NetworkSplitViewController(
        inspector: inspector,
        listViewController: NetworkListViewController(inspector: inspector),
        detailViewController: NetworkEntryDetailViewController(inspector: inspector)
    )
}
#endif
#endif

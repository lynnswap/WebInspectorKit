#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_NetworkSplitViewController: UISplitViewController {
    private let inspector: WINetworkModel
    private let listViewController: V2_NetworkListViewController
    private let detailViewController: V2_NetworkEntryDetailViewController
    private let primaryViewController: V2_NetworkListColumnNavigationController
    private let secondaryViewController: V2_WIRegularSplitColumnNavigationController

    init(
        inspector: WINetworkModel,
        listViewController: V2_NetworkListViewController,
        detailViewController: V2_NetworkEntryDetailViewController
    ) {
        self.inspector = inspector
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        primaryViewController = V2_NetworkListColumnNavigationController(
            rootViewController: listViewController
        )
        secondaryViewController = V2_WIRegularSplitColumnNavigationController(
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
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(primaryViewController, for: .primary)
        setViewController(secondaryViewController, for: .secondary)
    }

    private func showEntryDetail(_ entry: NetworkEntry?) {
        inspector.selectEntry(entry)
    }
}

@MainActor
private final class V2_NetworkListColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.wiDetachFromV2ContainerForReuse()
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

#Preview("V2 Network Split") {
    let network = V2_WINetworkRuntime()
    V2_NetworkSplitViewController(
        inspector: network.model,
        listViewController: V2_NetworkListViewController(inspector: network.model),
        detailViewController: V2_NetworkEntryDetailViewController(inspector: network.model)
    )
}
#endif
#endif

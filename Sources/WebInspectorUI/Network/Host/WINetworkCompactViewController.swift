import Foundation
import ObservationBridge
import WebInspectorCore
import WebInspectorCore

#if canImport(UIKit)
import UIKit

@MainActor
final class WINetworkCompactViewController: UINavigationController, UINavigationControllerDelegate {
    private let store: WINetworkStore
    private let listPaneViewController: WINetworkListViewController
    private var observationHandles: Set<ObservationHandle> = []

    init(store: WINetworkStore, queryModel: WINetworkQueryState) {
        self.store = store
        self.listPaneViewController = WINetworkListViewController(store: store, queryModel: queryModel)
        super.init(rootViewController: listPaneViewController)
        title = nil

        store.observe(\.selectedEntry, options: [.removeDuplicates]) { [weak self] newValue in
            guard let self else { return }
            self.syncNavigationStack(for: newValue)
        }
        .store(in: &observationHandles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wiApplyClearNavigationBarStyle(to: self)
        delegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyListNavigationItems()
    }

    private func pushDetailVC() {
        guard (topViewController as? WINetworkDetailViewController) == nil else {
            return
        }
        let vc = WINetworkDetailViewController(
            store: store,
            showsNavigationControls: true
        )
        pushViewController(vc, animated: true)
    }

    private func popToListVCIfNeeded() {
        guard topViewController !== listPaneViewController else {
            applyListNavigationItems()
            return
        }
        popToRootViewController(animated: true)
    }

    private func syncNavigationStack(for selectedEntry: NetworkEntry?) {
        guard selectedEntry != nil else {
            popToListVCIfNeeded()
            return
        }
        pushDetailVC()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated _: Bool
    ) {
        guard viewController === listPaneViewController else {
            return
        }
        if store.selectedEntry != nil {
            store.selectEntry(nil)
        }
        applyListNavigationItems()
    }

    private func applyListNavigationItems() {
        listPaneViewController.applyNavigationItems(to: listPaneViewController.navigationItem)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Compact Host (UIKit)") {
    let store = WINetworkPreviewFixtures.makeStore(mode: .detail)
    return WINetworkCompactViewController(
        store: store,
        queryModel: WINetworkQueryState(store: store)
    )
}
#endif
#endif

import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
final class WINetworkCompactViewController: UINavigationController, UINavigationControllerDelegate {
    private let inspector: WINetworkModel
    private let listPaneViewController: WINetworkListViewController
    private let observationScope = ObservationScope()

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.listPaneViewController = WINetworkListViewController(inspector: inspector, queryModel: queryModel)
        super.init(rootViewController: listPaneViewController)
        title = nil

        inspector.observe(\.selectedEntry) { [weak self] newValue in
            guard let self else { return }
            self.syncNavigationStack(for: newValue)
        }
        .store(in: observationScope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
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
            inspector: inspector,
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
        if inspector.selectedEntry != nil {
            inspector.selectEntry(nil)
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
    WIUIKitPreviewContainer {
        let inspector = WINetworkPreviewFixtures.makeInspector(mode: .detail)
        return WINetworkCompactViewController(
            inspector: inspector,
            queryModel: WINetworkQueryModel(inspector: inspector)
        )
    }
}
#endif
#endif

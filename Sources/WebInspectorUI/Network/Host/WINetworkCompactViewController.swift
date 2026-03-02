import Foundation
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
final class WINetworkCompactViewController: UINavigationController, UINavigationControllerDelegate {
    private let inspector: WINetworkModel
    private let listPaneViewController: WINetworkListViewController

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.listPaneViewController = WINetworkListViewController(inspector: inspector, queryModel: queryModel)
        super.init(rootViewController: listPaneViewController)
        title = nil

        inspector.observe(\.selectedEntry, options: [.removeDuplicates]) { [weak self] newValue in
            guard let self ,newValue != nil else { return }
            self.pushDetailVC()
        }
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
            inspector: inspector,
            showsNavigationControls: true
        )
        pushViewController(vc, animated: true)
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

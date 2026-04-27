#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_NetworkCompactNavigationController: V2_WICompactTabNavigationController, UINavigationControllerDelegate {
    private let inspector: WINetworkModel
    private let listViewController: V2_NetworkListViewController
    private let detailViewController: V2_NetworkEntryDetailViewController
    private var isSyncingStack = false

    init(
        inspector: WINetworkModel,
        listViewController: V2_NetworkListViewController,
        detailViewController: V2_NetworkEntryDetailViewController
    ) {
        self.inspector = inspector
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        super.init(rootViewController: listViewController)
        delegate = self
        listViewController.setEntrySelectionAction { [weak self] entry in
            self?.presentEntryDetail(entry)
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard isSyncingStack == false,
              viewController === listViewController,
              inspector.selectedEntry != nil else {
            return
        }
        inspector.selectEntry(nil)
    }

    private func presentEntryDetail(_ entry: NetworkEntry?) {
        inspector.selectEntry(entry)
        guard entry != nil else {
            popEntryDetailIfNeeded(animated: true)
            return
        }

        isSyncingStack = true
        defer {
            isSyncingStack = false
        }

        guard viewControllers.last !== detailViewController else {
            return
        }
        detailViewController.wiDetachFromV2ContainerForReuse()
        if viewControllers.first === listViewController {
            setViewControllers([listViewController, detailViewController], animated: true)
        } else {
            setViewControllers([listViewController, detailViewController], animated: false)
        }
    }

    private func popEntryDetailIfNeeded(animated: Bool) {
        isSyncingStack = true
        defer {
            isSyncingStack = false
        }

        guard viewControllers.count != 1 || viewControllers.first !== listViewController else {
            return
        }
        setViewControllers([listViewController], animated: animated)
    }
}
#endif

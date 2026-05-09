#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorRuntime

@MainActor
final class NetworkCompactNavigationController: WICompactTabNavigationController, UINavigationControllerDelegate {
    private let inspector: WINetworkModel
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkEntryDetailViewController
    private let observationScope = ObservationScope()
    private var isSyncingStack = false

    init(
        inspector: WINetworkModel,
        listViewController: NetworkListViewController,
        detailViewController: NetworkEntryDetailViewController
    ) {
        self.inspector = inspector
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        super.init(rootViewController: listViewController)
        delegate = self
        listViewController.setEntrySelectionAction { [weak inspector] entry in
            inspector?.selectEntry(entry)
        }
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncStack(with: inspector.selectedEntry, animated: false)
        startObservingSelection()
    }

    override func viewDidDisappear(_ animated: Bool) {
        stopObservingSelection()
        super.viewDidDisappear(animated)
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

    private func startObservingSelection() {
        observationScope.update {
            inspector.observe(\.selectedEntry) { [weak self] selectedEntry in
                self?.syncStack(with: selectedEntry, animated: true)
            }
            .store(in: observationScope)
        }
    }

    private func stopObservingSelection() {
        observationScope.cancelAll()
    }

    private func syncStack(with entry: NetworkEntry?, animated: Bool) {
        guard entry != nil else {
            popEntryDetailIfNeeded(animated: animated)
            return
        }

        isSyncingStack = true
        defer {
            isSyncingStack = false
        }

        guard viewControllers.last !== detailViewController else {
            return
        }
        detailViewController.wiDetachFromContainerForReuse()
        let shouldAnimate = animated && viewControllers.first === listViewController
        if viewControllers.first === listViewController {
            setViewControllers([listViewController, detailViewController], animated: shouldAnimate)
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

#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore

@MainActor
package final class NetworkCompactNavigationController: UINavigationController, UINavigationControllerDelegate {
    private let model: NetworkPanelModel
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController
    private let observationScope = ObservationScope()
    private var isSyncingStack = false
    private var isStackSyncScheduledAfterTransition = false
    private var pendingStackSyncAnimates = false

    package init(
        model: NetworkPanelModel,
        listViewController: NetworkListViewController,
        detailViewController: NetworkDetailViewController
    ) {
        self.model = model
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        listViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: listViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        webInspectorApplyClearNavigationBarStyle(to: self)
        delegate = self
        listViewController.setRequestSelectionAction { [weak model] request in
            model?.selectRequest(request)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncStack(with: model.selectedRequest, animated: false)
        startObservingSelection()
    }

    override package func viewDidDisappear(_ animated: Bool) {
        stopObservingSelection()
        super.viewDidDisappear(animated)
    }

    package func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        guard isSyncingStack == false,
              viewController === listViewController,
              model.selectedRequest != nil else {
            return
        }
        model.selectRequest(nil)
    }

    private func startObservingSelection() {
        observationScope.update {
            model.observe(\.selectedRequest) { [weak self] selectedRequest in
                self?.syncStack(with: selectedRequest, animated: true)
            }
            .store(in: observationScope)
        }
    }

    private func stopObservingSelection() {
        observationScope.cancelAll()
    }

    private func syncStack(with request: NetworkRequest?, animated: Bool) {
        guard scheduleStackSyncAfterCurrentTransitionIfNeeded(animated: animated) == false else {
            return
        }

        guard request != nil else {
            popRequestDetailIfNeeded(animated: animated)
            return
        }

        isSyncingStack = true
        defer {
            isSyncingStack = false
        }

        guard viewControllers.last !== detailViewController else {
            return
        }
        detailViewController.webInspectorDetachFromContainerForReuse()
        let shouldAnimate = animated && viewControllers.first === listViewController
        if viewControllers.first === listViewController {
            setViewControllers([listViewController, detailViewController], animated: shouldAnimate)
        } else {
            setViewControllers([listViewController, detailViewController], animated: false)
        }
    }

    private func popRequestDetailIfNeeded(animated: Bool) {
        isSyncingStack = true
        defer {
            isSyncingStack = false
        }

        guard viewControllers.count != 1 || viewControllers.first !== listViewController else {
            return
        }
        setViewControllers([listViewController], animated: animated)
    }

    private func scheduleStackSyncAfterCurrentTransitionIfNeeded(animated: Bool) -> Bool {
        guard let transitionCoordinator else {
            return false
        }

        pendingStackSyncAnimates = pendingStackSyncAnimates || animated
        guard isStackSyncScheduledAfterTransition == false else {
            return true
        }

        isStackSyncScheduledAfterTransition = true
        let didSchedule = transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.performPendingStackSyncAfterTransition()
        }
        if didSchedule {
            return true
        }

        isStackSyncScheduledAfterTransition = false
        pendingStackSyncAnimates = false
        return false
    }

    private func performPendingStackSyncAfterTransition() {
        guard isStackSyncScheduledAfterTransition else {
            return
        }

        isStackSyncScheduledAfterTransition = false
        let shouldAnimate = pendingStackSyncAnimates
        pendingStackSyncAnimates = false
        syncStack(with: model.selectedRequest, animated: shouldAnimate)
    }
}
#endif

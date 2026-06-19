#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class NetworkCompactNavigationController: UINavigationController, UINavigationControllerDelegate {
    private let model: NetworkPanelModel
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController
    private var selectionObservation: PortableObservationTracking.Token?
    private var isSyncingStack = false
    private var isStackSyncScheduledAfterTransition = false
    private var pendingStackSyncAnimates = false
    private var pendingDetailSurfaceDiscardAfterProgrammaticPop = false

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
        navigationBar.prefersLargeTitles = false
        navigationBar.scrollEdgeAppearance = navigationBar.standardAppearance
        navigationBar.compactScrollEdgeAppearance = navigationBar.compactAppearance ?? navigationBar.standardAppearance
        webInspectorApplyNavigationControllerBackground(to: self)
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
        selectionObservation?.cancel()
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncStack(hasSelection: model.selectedRequest != nil, animated: false)
        startObservingSelection()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { navigationController in
                navigationController.applyBackgroundFromTraits()
            }
        }
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
        guard viewController === listViewController else {
            return
        }
        if pendingDetailSurfaceDiscardAfterProgrammaticPop {
            pendingDetailSurfaceDiscardAfterProgrammaticPop = false
            detailViewController.discardDetailSurfaceAfterCompactRemoval()
            return
        }
        guard isSyncingStack == false,
              model.selectedRequest != nil else {
            return
        }
        model.selectRequest(nil)
        detailViewController.discardDetailSurfaceAfterCompactRemoval()
    }

    private func startObservingSelection() {
        selectionObservation?.cancel()
        selectionObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            syncStack(
                hasSelection: model.selectedRequest != nil,
                animated: event.kind != .initial
            )
        }
    }

    private func stopObservingSelection() {
        selectionObservation?.cancel()
        selectionObservation = nil
    }

    private func syncStack(hasSelection: Bool, animated: Bool) {
        guard scheduleStackSyncAfterCurrentTransitionIfNeeded(animated: animated) == false else {
            return
        }

        guard hasSelection else {
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
        if viewControllers.contains(where: { $0 === detailViewController }) {
            pendingDetailSurfaceDiscardAfterProgrammaticPop = true
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
        syncStack(hasSelection: model.selectedRequest != nil, animated: shouldAnimate)
    }

    private func applyBackgroundFromTraits() {
        webInspectorApplyNavigationControllerBackground(to: self)
    }
}

#if DEBUG
extension NetworkCompactNavigationController {
    package var selectionObservationDeliveryForTesting: PortableObservationTracking.Token? {
        selectionObservation
    }
}
#endif
#endif

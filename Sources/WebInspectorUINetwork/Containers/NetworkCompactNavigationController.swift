#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class NetworkCompactNavigationController: UINavigationController, UINavigationControllerDelegate {
    private enum StackTarget: Equatable {
        case list
        case detail
    }

    private enum StackTransition {
        case showingList
        case showingDetail
        case removingDetailForModel
        case removingDetailForUser(capturedIntentID: NetworkPanelSelectionIntent.ID?)

        var target: StackTarget {
            switch self {
            case .showingDetail:
                .detail
            case .showingList, .removingDetailForModel, .removingDetailForUser:
                .list
            }
        }

        var removesDetail: Bool {
            switch self {
            case .showingList, .showingDetail:
                false
            case .removingDetailForModel, .removingDetailForUser:
                true
            }
        }
    }

    private struct DeferredStackSync {
        var animated: Bool
    }

    private let model: NetworkPanelModel
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController
    private var selectionObservation: PortableObservationTracking.Token?
    private var activeTransition: StackTransition?
    private var deferredStackSync: DeferredStackSync?

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
        listViewController.setEntrySelectionAction { [weak model] entry in
            model?.selectEntry(entry)
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
        syncStack(to: desiredStackTarget(), animated: false)
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
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        guard viewController === listViewController else {
            return
        }
        let sourceViewController = activeTransition?.target == .detail
            ? detailViewController
            : transitionCoordinator?.viewController(forKey: .from)
        beginUserDetailRemovalIfNeeded(from: sourceViewController)
    }

    private func beginUserDetailRemovalIfNeeded(from sourceViewController: UIViewController?) {
        guard sourceViewController === detailViewController,
              activeTransition?.target != .list else {
            return
        }
        activeTransition = .removingDetailForUser(
            capturedIntentID: model.detailSubject?.intentID
        )
    }

    package func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        let shownTarget = stackTarget(for: viewController)
        finishActiveTransitionIfNeeded(shownTarget: shownTarget)
        let hadDeferredStackSync = deferredStackSync != nil
        performDeferredStackSyncIfNeeded()
        if hadDeferredStackSync == false {
            syncStack(to: desiredStackTarget(), animated: false)
        }
    }

    private func startObservingSelection() {
        selectionObservation?.cancel()
        selectionObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            syncStack(
                to: desiredStackTarget(),
                animated: event.kind != .initial
            )
        }
    }

    private func stopObservingSelection() {
        selectionObservation?.cancel()
        selectionObservation = nil
    }

    private func syncStack(to target: StackTarget, animated: Bool) {
        guard scheduleStackSyncAfterCurrentTransitionIfNeeded(animated: animated) == false else {
            return
        }

        guard currentStackTarget() != target else {
            return
        }

        switch target {
        case .list:
            popRequestDetailIfNeeded(animated: animated)
        case .detail:
            pushRequestDetailIfNeeded(animated: animated)
        }
    }

    private func pushRequestDetailIfNeeded(animated: Bool) {
        guard viewControllers.last !== detailViewController else {
            return
        }
        detailViewController.webInspectorDetachFromContainerForReuse()
        let shouldAnimate = animated && viewControllers.first === listViewController
        activeTransition = .showingDetail
        if viewControllers.first === listViewController {
            setViewControllers([listViewController, detailViewController], animated: shouldAnimate)
        } else {
            setViewControllers([listViewController, detailViewController], animated: false)
        }
        finishActiveTransitionIfNoCoordinator()
    }

    private func popRequestDetailIfNeeded(animated: Bool) {
        guard viewControllers.count != 1 || viewControllers.first !== listViewController else {
            return
        }
        activeTransition = viewControllers.contains { $0 === detailViewController }
            ? .removingDetailForModel
            : .showingList
        setViewControllers([listViewController], animated: animated)
        finishActiveTransitionIfNoCoordinator()
    }

    private func scheduleStackSyncAfterCurrentTransitionIfNeeded(animated: Bool) -> Bool {
        if activeTransition != nil {
            mergeDeferredStackSync(animated: animated)
            return true
        }
        guard let transitionCoordinator else {
            return false
        }

        let hadDeferredSync = deferredStackSync != nil
        mergeDeferredStackSync(animated: animated)
        guard hadDeferredSync == false else {
            return true
        }

        let didSchedule = transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.performDeferredStackSyncIfNeeded()
        }
        if didSchedule {
            return true
        }

        deferredStackSync = nil
        return false
    }

    private func mergeDeferredStackSync(animated: Bool) {
        let shouldAnimate = (deferredStackSync?.animated ?? false) || animated
        deferredStackSync = DeferredStackSync(animated: shouldAnimate)
    }

    private func performDeferredStackSyncIfNeeded() {
        guard let deferredStackSync else {
            return
        }
        self.deferredStackSync = nil
        syncStack(to: desiredStackTarget(), animated: deferredStackSync.animated)
    }

    private func finishActiveTransitionIfNoCoordinator() {
        guard transitionCoordinator == nil else {
            return
        }
        finishActiveTransitionIfNeeded(shownTarget: currentStackTarget())
    }

    private func finishActiveTransitionIfNeeded(shownTarget: StackTarget?) {
        guard let transition = activeTransition else {
            return
        }
        activeTransition = nil
        guard shownTarget == transition.target else {
            return
        }

        commit(transition)
    }

    private func commit(_ transition: StackTransition) {
        if case .removingDetailForUser(let capturedIntentID) = transition,
           let capturedIntentID {
            model.clearSelection(ifIntentUnchanged: capturedIntentID)
        }
        guard transition.removesDetail else {
            return
        }
        detailViewController.discardDetailSurfaceAfterCompactRemoval()
    }

    private func desiredStackTarget() -> StackTarget {
        model.detailSubject == nil ? .list : .detail
    }

    private func currentStackTarget() -> StackTarget {
        stackTarget(for: viewControllers.last) ?? .list
    }

    private func stackTarget(for viewController: UIViewController?) -> StackTarget? {
        if viewController === detailViewController {
            return .detail
        }
        if viewController === listViewController {
            return .list
        }
        return nil
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

    package func resumeSelectionObservationForTesting() {
        loadViewIfNeeded()
        syncStackForTesting()
        startObservingSelection()
    }

    package func syncStackForTesting() {
        syncStack(to: desiredStackTarget(), animated: false)
    }

    @discardableResult
    package func popDetailWhilePushTransitionIsStillTrackedForTesting(
        beforeTransitionCompletion: () -> Void = {}
    )
        -> UIViewController?
    {
        guard viewControllers.last === detailViewController else {
            return nil
        }

        activeTransition = .showingDetail
        navigationController(
            self,
            willShow: listViewController,
            animated: false
        )
        let poppedViewController = popViewController(animated: false)
        beforeTransitionCompletion()
        navigationController(
            self,
            didShow: listViewController,
            animated: false
        )
        return poppedViewController
    }

    @discardableResult
    package func popDetailFromUserNavigationForTesting(
        beforeTransitionCompletion: () -> Void = {}
    ) -> UIViewController? {
        guard viewControllers.last === detailViewController else {
            return nil
        }

        activeTransition = .removingDetailForUser(
            capturedIntentID: model.detailSubject?.intentID
        )
        let poppedViewController = popViewController(animated: false)
        beforeTransitionCompletion()
        finishActiveTransitionIfNeeded(shownTarget: .list)
        performDeferredStackSyncIfNeeded()
        return poppedViewController
    }

    package func cancelDetailPopFromUserNavigationForTesting(
        beforeTransitionCompletion: () -> Void = {}
    ) {
        guard viewControllers.last === detailViewController else {
            return
        }

        activeTransition = .removingDetailForUser(
            capturedIntentID: model.detailSubject?.intentID
        )
        beforeTransitionCompletion()
        finishActiveTransitionIfNeeded(shownTarget: .detail)
        performDeferredStackSyncIfNeeded()
    }

    package func cancelDetailPopWhilePushTransitionIsStillTrackedForTesting(
        beforeTransitionCompletion: () -> Void = {}
    ) {
        guard viewControllers.last === detailViewController else {
            return
        }

        activeTransition = .showingDetail
        navigationController(
            self,
            willShow: listViewController,
            animated: false
        )
        beforeTransitionCompletion()
        navigationController(
            self,
            didShow: detailViewController,
            animated: false
        )
    }
}
#endif
#endif

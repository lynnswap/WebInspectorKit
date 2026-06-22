#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class NetworkCompactNavigationController: UINavigationController, UINavigationControllerDelegate {
    private enum StackTarget {
        case list
        case detail
    }

    private enum SelectionCommit {
        case none
        case clearIfStillSelected(NetworkDisplayEntry.ID)

        @MainActor
        func apply(to model: NetworkPanelModel) {
            switch self {
            case .none:
                return
            case .clearIfStillSelected(let entryID):
                guard model.selectedEntryID == entryID else {
                    return
                }
                model.selectEntry(nil)
            }
        }
    }

    private struct StackTransition {
        var target: StackTarget
        var removesDetail: Bool
        var selectionCommit: SelectionCommit
    }

    private struct DeferredStackSync {
        var target: StackTarget
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
        listViewController.setEntrySelectionAction { [weak model] entryID in
            model?.selectEntry(entryID)
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
        guard viewController === listViewController,
              activeTransition == nil,
              transitionCoordinator?.viewController(forKey: .from) === detailViewController else {
            return
        }
        activeTransition = StackTransition(
            target: .list,
            removesDetail: true,
            selectionCommit: userPopSelectionCommit()
        )
    }

    package func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        let shownTarget = stackTarget(for: viewController)
        if finishActiveTransitionIfNeeded(shownTarget: shownTarget) == false {
            finishUntrackedDetailRemovalIfNeeded(shownTarget: shownTarget)
        }
        performDeferredStackSyncIfNeeded()
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
        guard scheduleStackSyncAfterCurrentTransitionIfNeeded(to: target, animated: animated) == false else {
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
        activeTransition = StackTransition(
            target: .detail,
            removesDetail: false,
            selectionCommit: .none
        )
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
        activeTransition = StackTransition(
            target: .list,
            removesDetail: viewControllers.contains { $0 === detailViewController },
            selectionCommit: .none
        )
        setViewControllers([listViewController], animated: animated)
        finishActiveTransitionIfNoCoordinator()
    }

    private func scheduleStackSyncAfterCurrentTransitionIfNeeded(to target: StackTarget, animated: Bool) -> Bool {
        if activeTransition != nil {
            mergeDeferredStackSync(to: target, animated: animated)
            return true
        }
        guard let transitionCoordinator else {
            return false
        }

        let hadDeferredSync = deferredStackSync != nil
        mergeDeferredStackSync(to: target, animated: animated)
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

    private func mergeDeferredStackSync(to target: StackTarget, animated: Bool) {
        let shouldAnimate = (deferredStackSync?.animated ?? false) || animated
        deferredStackSync = DeferredStackSync(target: target, animated: shouldAnimate)
    }

    private func performDeferredStackSyncIfNeeded() {
        guard let deferredStackSync else {
            return
        }
        self.deferredStackSync = nil
        syncStack(to: deferredStackSync.target, animated: deferredStackSync.animated)
    }

    private func finishActiveTransitionIfNoCoordinator() {
        guard transitionCoordinator == nil else {
            return
        }
        _ = finishActiveTransitionIfNeeded(shownTarget: currentStackTarget())
    }

    @discardableResult
    private func finishActiveTransitionIfNeeded(shownTarget: StackTarget?) -> Bool {
        guard let transition = activeTransition else {
            return false
        }
        activeTransition = nil
        guard shownTarget == transition.target else {
            return true
        }

        commit(transition)
        return true
    }

    private func finishUntrackedDetailRemovalIfNeeded(shownTarget: StackTarget?) {
        guard shownTarget == .list,
              model.selectedEntryID != nil else {
            return
        }
        commit(
            StackTransition(
                target: .list,
                removesDetail: true,
                selectionCommit: userPopSelectionCommit()
            )
        )
    }

    private func commit(_ transition: StackTransition) {
        transition.selectionCommit.apply(to: model)
        guard transition.removesDetail else {
            return
        }
        detailViewController.discardDetailSurfaceAfterCompactRemoval()
    }

    private func desiredStackTarget() -> StackTarget {
        model.selectedEntry == nil ? .list : .detail
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

    private func userPopSelectionCommit() -> SelectionCommit {
        guard let selectedEntryID = model.selectedEntryID else {
            return .none
        }
        return .clearIfStillSelected(selectedEntryID)
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

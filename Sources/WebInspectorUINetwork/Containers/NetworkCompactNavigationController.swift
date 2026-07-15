#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
package final class NetworkCompactNavigationController:
    UINavigationController,
    UINavigationControllerDelegate
{
    private enum StackTarget: Equatable {
        case list
        case detail
    }

    private enum Transition {
        case programmatic(StackTarget)
        case userPop(previousEntryID: NetworkEntry.ID)
    }

    private let model: NetworkPanelModel
    private let listViewController: NetworkListViewController
    private let detailViewController: NetworkDetailViewController
    private var routeObservation: PortableObservationTracking.Token?
    private var transition: Transition?
    private var needsReconciliation = false

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
        navigationBar.compactScrollEdgeAppearance =
            navigationBar.compactAppearance ?? navigationBar.standardAppearance
        webInspectorApplyNavigationControllerBackground(to: self)
        delegate = self
        listViewController.setEntrySelectionAction { [weak model] entryID in
            model?.selectEntry(entryID)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        routeObservation?.cancel()
    }

    override package func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reconcileStack(animated: false)
        startObservingRoute()
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
        routeObservation?.cancel()
        routeObservation = nil
        super.viewDidDisappear(animated)
    }

    package func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        guard transition == nil,
              viewController === listViewController,
              isTransitioningFromDetailToList(in: navigationController),
              case let .detail(entryID) = model.route else {
            return
        }

        // Commit the route before UIKit reconciles the stack. Observation can
        // therefore never see a still-selected detail after a completed pop.
        transition = .userPop(previousEntryID: entryID)
        model.showList()
    }

    private func isTransitioningFromDetailToList(
        in navigationController: UINavigationController
    ) -> Bool {
        if let coordinator = navigationController.transitionCoordinator {
            return coordinator.viewController(forKey: .from)
                === detailViewController
                && coordinator.viewController(forKey: .to)
                === listViewController
        }

        // Nonanimated stack changes can synchronously invoke the delegate
        // without installing a transition coordinator.
        return self.viewControllers.last === detailViewController
    }

    package func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        finishTransition(shown: stackTarget(for: viewController))
    }

    private func startObservingRoute() {
        routeObservation?.cancel()
        routeObservation = withPortableContinuousObservation { [weak self] event in
            self?.reconcileStack(animated: event.kind != .initial)
        }
    }

    private func reconcileStack(animated: Bool) {
        guard transition == nil, transitionCoordinator == nil else {
            needsReconciliation = true
            return
        }
        let desired = desiredStackTarget
        guard currentStackTarget != desired else { return }

        transition = .programmatic(desired)
        switch desired {
        case .list:
            setViewControllers([listViewController], animated: animated)
        case .detail:
            detailViewController.webInspectorDetachFromContainerForReuse()
            setViewControllers(
                [listViewController, detailViewController],
                animated: animated
            )
        }
        if transition != nil, transitionCoordinator == nil {
            finishTransition(shown: currentStackTarget)
        }
    }

    private func finishTransition(shown: StackTarget?) {
        guard let transition else {
            reconcileDeferredStackIfNeeded()
            return
        }
        self.transition = nil

        switch transition {
        case .programmatic(.list):
            if shown == .list {
                detailViewController.discardDetailSurfaceAfterCompactRemoval()
            }
        case .programmatic(.detail):
            break
        case let .userPop(previousEntryID):
            if shown == .detail {
                // Interactive cancellation restores the route that UIKit kept.
                model.showDetail(previousEntryID)
            } else if shown == .list {
                detailViewController.discardDetailSurfaceAfterCompactRemoval()
            }
        }
        reconcileDeferredStackIfNeeded()
    }

    private func reconcileDeferredStackIfNeeded() {
        let shouldReconcile = needsReconciliation
        needsReconciliation = false
        if shouldReconcile || currentStackTarget != desiredStackTarget {
            reconcileStack(animated: false)
        }
    }

    private var desiredStackTarget: StackTarget {
        if case .detail = model.route { return .detail }
        return .list
    }

    private var currentStackTarget: StackTarget {
        stackTarget(for: viewControllers.last) ?? .list
    }

    private func stackTarget(for viewController: UIViewController?) -> StackTarget? {
        if viewController === detailViewController { return .detail }
        if viewController === listViewController { return .list }
        return nil
    }

    private func applyBackgroundFromTraits() {
        webInspectorApplyNavigationControllerBackground(to: self)
    }
}

#if DEBUG
extension NetworkCompactNavigationController {
    package var selectionObservationDeliveryForTesting:
        PortableObservationTracking.Token? {
        routeObservation
    }

    package func resumeSelectionObservationForTesting() {
        loadViewIfNeeded()
        reconcileStack(animated: false)
        startObservingRoute()
    }

    package func syncStackForTesting() {
        reconcileStack(animated: false)
    }

    @discardableResult
    package func popDetailFromUserNavigationForTesting() -> UIViewController? {
        guard viewControllers.last === detailViewController else { return nil }
        navigationController(self, willShow: listViewController, animated: false)
        let popped = popViewController(animated: false)
        navigationController(self, didShow: listViewController, animated: false)
        return popped
    }
}
#endif
#endif

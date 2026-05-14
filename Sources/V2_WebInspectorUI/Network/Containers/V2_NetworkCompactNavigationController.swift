#if canImport(UIKit)
import ObservationBridge
import UIKit
import V2_WebInspectorCore

@MainActor
package final class V2_NetworkCompactNavigationController: UINavigationController, UINavigationControllerDelegate {
    private let model: V2_NetworkPanelModel
    private let listViewController: V2_NetworkListViewController
    private let detailViewController: V2_NetworkDetailViewController
    private let observationScope = ObservationScope()
    private var isSyncingStack = false

    package init(
        model: V2_NetworkPanelModel,
        listViewController: V2_NetworkListViewController,
        detailViewController: V2_NetworkDetailViewController
    ) {
        self.model = model
        self.listViewController = listViewController
        self.detailViewController = detailViewController
        listViewController.v2WIDetachFromContainerForReuse()
        super.init(rootViewController: listViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        v2WIApplyClearNavigationBarStyle(to: self)
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
        detailViewController.v2WIDetachFromContainerForReuse()
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
}
#endif

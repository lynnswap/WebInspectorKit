import Foundation
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
final class WINetworkCompactViewController: UIViewController, UINavigationControllerDelegate {
    private let inspector: WINetworkModel
    private let queryModel: WINetworkQueryModel
    private let listPaneViewController: WINetworkListViewController
    private var detailViewController: WINetworkDetailViewController?
    private var hasStartedObservingInspector = false
    private let selectionUpdateCoalescer = UIUpdateCoalescer()
    private weak var previousNavigationControllerDelegate: UINavigationControllerDelegate?

    init(inspector: WINetworkModel, queryModel: WINetworkQueryModel) {
        self.inspector = inspector
        self.queryModel = queryModel
        self.listPaneViewController = WINetworkListViewController(inspector: inspector, queryModel: queryModel)
        super.init(nibName: nil, bundle: nil)
        title = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        addChild(listPaneViewController)
        listPaneViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(listPaneViewController.view)
        NSLayoutConstraint.activate([
            listPaneViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            listPaneViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listPaneViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listPaneViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        listPaneViewController.didMove(toParent: self)

        startObservingInspectorIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attachNavigationControllerDelegateIfNeeded()
        listPaneViewController.applyNavigationItems(to: navigationItem)
        syncDetailSelection(animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        detachNavigationControllerDelegateIfNeeded()
    }

    private func startObservingInspectorIfNeeded() {
        guard hasStartedObservingInspector == false else {
            return
        }
        hasStartedObservingInspector = true
        inspector.observeTask(
            [
                \.selectedEntry
            ]
        ) { [weak self] in
            self?.scheduleSelectionSync(animated: false)
        }
        inspector.store.observeTask(
            [
                \.entries
            ]
        ) { [weak self] in
            self?.scheduleSelectionSync(animated: false)
        }
    }

    private func scheduleSelectionSync(animated: Bool) {
        selectionUpdateCoalescer.schedule { [weak self] in
            self?.syncDetailSelection(animated: animated)
        }
    }

    private func attachNavigationControllerDelegateIfNeeded() {
        guard let navigationController else {
            return
        }
        guard navigationController.delegate !== self else {
            return
        }
        previousNavigationControllerDelegate = navigationController.delegate
        navigationController.delegate = self
    }

    private func detachNavigationControllerDelegateIfNeeded() {
        guard let navigationController, navigationController.delegate === self else {
            return
        }
        navigationController.delegate = previousNavigationControllerDelegate
        previousNavigationControllerDelegate = nil
    }

    private func syncDetailSelection(animated: Bool) {
        let selectedEntry = inspector.revalidateSelectedEntryAgainstStore()
        listPaneViewController.selectEntry(with: selectedEntry?.id)

        guard let selectedEntry else {
            popToListIfNeeded(animated: animated)
            detailViewController?.display(nil, hasEntries: !inspector.store.entries.isEmpty)
            return
        }

        showDetailIfNeeded(for: selectedEntry, animated: animated)
    }

    private func showDetailIfNeeded(for entry: NetworkEntry, animated: Bool) {
        if let detailViewController {
            detailViewController.display(entry, hasEntries: !inspector.store.entries.isEmpty)
            guard let navigationController else {
                return
            }
            if navigationController.topViewController === detailViewController {
                return
            }
            if navigationController.viewControllers.contains(where: { $0 === detailViewController }) {
                return
            }
            navigationController.pushViewController(detailViewController, animated: animated)
            return
        }

        let detailViewController = WINetworkDetailViewController(
            inspector: inspector,
            showsNavigationControls: true
        )
        detailViewController.display(entry, hasEntries: !inspector.store.entries.isEmpty)

        self.detailViewController = detailViewController
        navigationController?.pushViewController(detailViewController, animated: animated)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated _: Bool
    ) {
        guard viewController === self else {
            return
        }
        guard let detailViewController else {
            return
        }
        guard navigationController.viewControllers.contains(where: { $0 === detailViewController }) == false else {
            return
        }

        inspector.selectEntry(id: nil)
        self.detailViewController = nil
        listPaneViewController.selectEntry(with: nil)
        listPaneViewController.applyNavigationItems(to: navigationItem)
    }

    private func popToListIfNeeded(animated: Bool) {
        guard let navigationController else {
            return
        }
        guard navigationController.topViewController !== self else {
            return
        }
        navigationController.popToViewController(self, animated: animated)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Compact Host (UIKit)") {
    WIUIKitPreviewContainer {
        let inspector = WINetworkPreviewFixtures.makeInspector(mode: .detail)
        return UINavigationController(
            rootViewController: WINetworkCompactViewController(
                inspector: inspector,
                queryModel: WINetworkQueryModel(inspector: inspector)
            )
        )
    }
}
#endif
#endif

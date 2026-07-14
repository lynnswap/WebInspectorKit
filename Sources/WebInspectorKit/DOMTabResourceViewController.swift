#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM

@MainActor
package final class DOMTabResourceViewController: UIViewController {
    package enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private let retryAction: @MainActor () -> Void
    private let makeReadyViewController: @MainActor (DOMPanelModel)
        -> UIViewController
    private var readyViewController: UIViewController?
    package private(set) var phase: Phase = .loading

    package init(
        retryAction: @escaping @MainActor () -> Void,
        makeReadyViewController: @escaping @MainActor (DOMPanelModel)
            -> UIViewController
    ) {
        self.retryAction = retryAction
        self.makeReadyViewController = makeReadyViewController
        super.init(nibName: nil, bundle: nil)
        showLoading()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package func showLoading() {
        phase = .loading
        removeReadyViewController()
        var configuration = UIContentUnavailableConfiguration.loading()
        configuration.text = String(
            localized: "dom.loading.title",
            defaultValue: "Loading DOM…",
            bundle: WebInspectorUILocalization.bundle
        )
        contentUnavailableConfiguration = configuration
    }

    package func showReady(_ model: DOMPanelModel) {
        phase = .ready
        contentUnavailableConfiguration = nil
        installReadyViewController(makeReadyViewController(model))
    }

    package func showFailure(_ message: String) {
        phase = .failed(message)
        removeReadyViewController()
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "exclamationmark.triangle")
        configuration.text = String(
            localized: "dom.loading.failed.title",
            defaultValue: "DOM Unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.secondaryText = message
        configuration.button = .bordered()
        configuration.button.title = String(
            localized: "resource.retry",
            defaultValue: "Retry",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.retryAction()
        }
        contentUnavailableConfiguration = configuration
    }

    package func synchronouslyResetForOwnerDeinit() {
        showLoading()
    }

    private func installReadyViewController(_ viewController: UIViewController) {
        guard readyViewController !== viewController else { return }
        removeReadyViewController()
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        viewController.didMove(toParent: self)
        readyViewController = viewController
        navigationItem.leadingItemGroups = viewController.navigationItem.leadingItemGroups
        navigationItem.trailingItemGroups = viewController.navigationItem.trailingItemGroups
        navigationItem.additionalOverflowItems = viewController.navigationItem.additionalOverflowItems
    }

    private func removeReadyViewController() {
        guard let readyViewController else { return }
        readyViewController.willMove(toParent: nil)
        readyViewController.viewIfLoaded?.removeFromSuperview()
        readyViewController.removeFromParent()
        self.readyViewController = nil
        navigationItem.leadingItemGroups = []
        navigationItem.trailingItemGroups = []
        navigationItem.additionalOverflowItems = nil
    }

    #if DEBUG
    package var readyViewControllerForTesting: UIViewController? {
        readyViewController
    }
    #endif
}
#endif

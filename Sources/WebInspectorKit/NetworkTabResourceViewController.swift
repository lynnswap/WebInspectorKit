#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUINetwork

@MainActor
package final class NetworkTabResourceViewController: UIViewController {
    package enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
        case closed
    }

    private let makeReadyViewController: @MainActor (NetworkPanelModel)
        -> UIViewController
    private var readyViewController: UIViewController?
    package private(set) var phase: Phase = .loading

    package init(
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel)
            -> UIViewController
    ) {
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
            localized: "network.loading.title",
            defaultValue: "Loading Network…",
            bundle: WebInspectorUILocalization.bundle
        )
        contentUnavailableConfiguration = configuration
    }

    package func showReady(_ model: NetworkPanelModel) {
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
            localized: "network.error.title",
            defaultValue: "Network Error",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.secondaryText = message
        contentUnavailableConfiguration = configuration
    }

    package func showClosed() {
        phase = .closed
        removeReadyViewController()
        contentUnavailableConfiguration = nil
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
    }

    private func removeReadyViewController() {
        guard let readyViewController else { return }
        readyViewController.willMove(toParent: nil)
        readyViewController.viewIfLoaded?.removeFromSuperview()
        readyViewController.removeFromParent()
        self.readyViewController = nil
    }

    #if DEBUG
    package var readyViewControllerForTesting: UIViewController? {
        readyViewController
    }
    #endif
}
#endif

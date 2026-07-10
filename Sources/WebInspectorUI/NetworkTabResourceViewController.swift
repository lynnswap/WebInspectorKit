#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUINetwork

/// Native loading/failure container for one Network tab host presentation.
@MainActor
package final class NetworkTabResourceViewController: UIViewController {
    package enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private let makeReadyViewController: @MainActor (NetworkPanelModel) -> UIViewController
    private var readyViewController: UIViewController?
    private var hasRenderedResourceState = false
    package private(set) var phase: Phase = .loading
    package private(set) var resourceRevision: UInt64 = 0

    package init(
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) {
        self.makeReadyViewController = makeReadyViewController
        super.init(nibName: nil, bundle: nil)
        showLoading(revision: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    package func showLoading(revision: UInt64) {
        guard shouldRender(revision: revision) else {
            return
        }
        resourceRevision = revision
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

    package func showReady(_ model: NetworkPanelModel, revision: UInt64) {
        guard shouldRender(revision: revision) else {
            return
        }
        resourceRevision = revision
        phase = .ready
        contentUnavailableConfiguration = nil
        let viewController = makeReadyViewController(model)
        installReadyViewController(viewController)
    }

    package func showFailure(_ message: String, revision: UInt64) {
        guard shouldRender(revision: revision) else {
            return
        }
        resourceRevision = revision
        phase = .failed(message)
        removeReadyViewController()
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "exclamationmark.triangle")
        configuration.text = String(
            localized: "network.loading.failed.title",
            defaultValue: "Network Unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.secondaryText = message
        contentUnavailableConfiguration = configuration
    }

    /// Drops ready content when the root resource owner can no longer publish.
    package func synchronouslyResetForOwnerDeinit() {
        showLoading(revision: .max)
    }

    private func shouldRender(revision: UInt64) -> Bool {
        guard hasRenderedResourceState == false || resourceRevision < revision else {
            return false
        }
        hasRenderedResourceState = true
        return true
    }

    private func installReadyViewController(_ viewController: UIViewController) {
        guard readyViewController !== viewController else {
            return
        }
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
        guard let readyViewController else {
            return
        }
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

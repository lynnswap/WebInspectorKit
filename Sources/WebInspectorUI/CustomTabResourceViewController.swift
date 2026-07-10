#if canImport(UIKit)
import UIKit
import WebInspectorUIBase

/// Native loading/failure host for one presentation of a custom tab resource.
///
/// UIKit owns this wrapper's identity. The root presentation store owns the
/// single ready content controller and moves it between wrappers as host layout
/// changes.
@MainActor
package final class CustomTabResourceViewController: UIViewController {
    package enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private let retryAction: @MainActor () -> Void
    private var readyViewController: UIViewController?
    package private(set) var phase: Phase = .loading
    package private(set) var resourceRevision: UInt64 = 0

    package init(retryAction: @escaping @MainActor () -> Void) {
        self.retryAction = retryAction
        super.init(nibName: nil, bundle: nil)
        showLoading(revision: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    package func showLoading(revision: UInt64) {
        guard revision >= resourceRevision else {
            return
        }
        resourceRevision = revision
        phase = .loading
        removeReadyViewController()
        var configuration = UIContentUnavailableConfiguration.loading()
        configuration.text = String(
            localized: "custom.loading.title",
            defaultValue: "Loading…",
            bundle: WebInspectorUILocalization.bundle
        )
        contentUnavailableConfiguration = configuration
    }

    package func showReady(
        _ viewController: UIViewController,
        revision: UInt64
    ) {
        guard revision >= resourceRevision else {
            return
        }
        resourceRevision = revision
        phase = .ready
        contentUnavailableConfiguration = nil
        installReadyViewController(viewController)
    }

    package func showFailure(_ message: String, revision: UInt64) {
        guard revision >= resourceRevision else {
            return
        }
        resourceRevision = revision
        phase = .failed(message)
        removeReadyViewController()
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "exclamationmark.triangle")
        configuration.text = String(
            localized: "custom.loading.failed.title",
            defaultValue: "Content Unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.secondaryText = message
        configuration.button = .bordered()
        configuration.button.title = String(
            localized: "custom.loading.retry",
            defaultValue: "Retry",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.retryAction()
        }
        contentUnavailableConfiguration = configuration
    }

    package func synchronouslyResetForOwnerDeinit() {
        showLoading(revision: .max)
    }

    private func installReadyViewController(_ viewController: UIViewController) {
        if readyViewController === viewController,
           viewController.parent === self {
            return
        }
        if let previousHost = viewController.parent as? CustomTabResourceViewController {
            previousHost.removeReadyViewController()
        } else {
            viewController.webInspectorDetachFromContainerForReuse()
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
        if readyViewController.parent === self {
            readyViewController.willMove(toParent: nil)
            readyViewController.viewIfLoaded?.removeFromSuperview()
            readyViewController.removeFromParent()
        }
        self.readyViewController = nil
    }

    #if DEBUG
    package var readyViewControllerForTesting: UIViewController? {
        readyViewController
    }

    package func retryForTesting() {
        retryAction()
    }
    #endif
}
#endif

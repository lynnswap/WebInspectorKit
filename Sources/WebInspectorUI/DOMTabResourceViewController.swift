#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM

/// Native loading/failure container for one DOM tab host presentation.
@MainActor
package final class DOMTabResourceViewController: UIViewController {
    package enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private let makeReadyViewController: @MainActor (DOMPanelModel)
        -> UIViewController
    private var readyViewController: UIViewController?
    private var hasRenderedResourceState = false
    package private(set) var phase: Phase = .loading
    package private(set) var resourceRevision: UInt64 = 0

    package init(
        makeReadyViewController: @escaping @MainActor (DOMPanelModel)
            -> UIViewController
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
            localized: "dom.loading.title",
            defaultValue: "Loading DOM…",
            bundle: WebInspectorUILocalization.bundle
        )
        contentUnavailableConfiguration = configuration
    }

    package func showReady(_ model: DOMPanelModel, revision: UInt64) {
        guard shouldRender(revision: revision) else {
            return
        }
        resourceRevision = revision
        phase = .ready
        contentUnavailableConfiguration = nil
        installReadyViewController(makeReadyViewController(model))
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
            localized: "dom.loading.failed.title",
            defaultValue: "DOM Unavailable",
            bundle: WebInspectorUILocalization.bundle
        )
        configuration.secondaryText = message
        contentUnavailableConfiguration = configuration
    }

    package func synchronouslyResetForOwnerDeinit() {
        showLoading(revision: .max)
    }

    private func shouldRender(revision: UInt64) -> Bool {
        guard hasRenderedResourceState == false || resourceRevision < revision
        else {
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
        navigationItem.leadingItemGroups =
            viewController.navigationItem.leadingItemGroups
        navigationItem.trailingItemGroups =
            viewController.navigationItem.trailingItemGroups
        navigationItem.additionalOverflowItems =
            viewController.navigationItem.additionalOverflowItems
    }

    private func removeReadyViewController() {
        guard let readyViewController else {
            return
        }
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

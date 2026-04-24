#if canImport(UIKit)
import UIKit
import WebInspectorKit

@MainActor
final class BrowserInspectorWindowHostingController: UIViewController {
    private struct AppliedInspectorContext: Equatable {
        let inspectorControllerID: ObjectIdentifier
        let browserStoreID: ObjectIdentifier
    }

    private var inspectorContainer: V2_WITabBarController?
    private let placeholderLabel = UILabel()
    private var lastAppliedContext: AppliedInspectorContext?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        placeholderLabel.text = "Inspector unavailable"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        updateInspectorContext()
    }

    isolated deinit {
        inspectorContainer?.detachFromMonoclyBrowser()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            removeInspectorContainerIfNeeded()
            lastAppliedContext = nil
        }
    }

    func updateInspectorContext() {
        guard let inspectorContext = BrowserInspectorCoordinator.inspectorWindowContext() else {
            lastAppliedContext = nil
            removeInspectorContainerIfNeeded()
            installPlaceholderIfNeeded()
            return
        }

        let appliedContext = AppliedInspectorContext(
            inspectorControllerID: ObjectIdentifier(inspectorContext.inspectorController),
            browserStoreID: ObjectIdentifier(inspectorContext.browserStore)
        )

        if lastAppliedContext == appliedContext {
            return
        }

        removeInspectorContainerIfNeeded()

        placeholderLabel.removeFromSuperview()
        let container = V2_WITabBarController()
        addChild(container)
        container.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container.view)
        NSLayoutConstraint.activate([
            container.view.topAnchor.constraint(equalTo: view.topAnchor),
            container.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        container.didMove(toParent: self)
        container.attachToMonoclyBrowser(inspectorContext.browserStore)
        inspectorContainer = container
        lastAppliedContext = appliedContext
    }

    private func removeInspectorContainerIfNeeded() {
        guard let inspectorContainer else {
            return
        }
        inspectorContainer.detachFromMonoclyBrowser()
        inspectorContainer.willMove(toParent: nil)
        inspectorContainer.view.removeFromSuperview()
        inspectorContainer.removeFromParent()
        self.inspectorContainer = nil
    }

    private func installPlaceholderIfNeeded() {
        guard placeholderLabel.superview == nil else {
            return
        }
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}
#endif

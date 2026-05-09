#if canImport(UIKit)
import UIKit
import WebInspectorKit

@MainActor
final class BrowserInspectorWindowHostingController: UIViewController {
    private struct AppliedInspectorContext: Equatable {
        let inspectorRuntimeID: ObjectIdentifier
        let browserStoreID: ObjectIdentifier
        let tabIDs: [WITab.ID]
    }

    private var inspectorContainer: WIViewController?
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
            inspectorRuntimeID: ObjectIdentifier(inspectorContext.inspectorRuntime),
            browserStoreID: ObjectIdentifier(inspectorContext.browserStore),
            tabIDs: inspectorContext.tabs.map(\.id)
        )

        if lastAppliedContext == appliedContext {
            return
        }

        removeInspectorContainerIfNeeded()

        placeholderLabel.removeFromSuperview()
        let container = WIViewController(
            session: WISession(
                runtime: inspectorContext.inspectorRuntime,
                tabs: inspectorContext.tabs
            )
        )
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
        inspectorContainer = container
        lastAppliedContext = appliedContext
    }

    private func removeInspectorContainerIfNeeded() {
        guard let inspectorContainer else {
            return
        }
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

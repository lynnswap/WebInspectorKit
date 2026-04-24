#if canImport(UIKit)
import UIKit
import WebInspectorKit

@MainActor
final class BrowserInspectorWindowHostingController: UIViewController {
    private struct AppliedInspectorContext: Equatable {
        let inspectorControllerID: ObjectIdentifier
    }

    private var inspectorContainer: UIViewController?
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

    func updateInspectorContext() {
        guard let inspectorContext = BrowserInspectorCoordinator.inspectorWindowContext() else {
            lastAppliedContext = nil
            if inspectorContainer == nil {
                installPlaceholderIfNeeded()
            }
            return
        }

        let appliedContext = AppliedInspectorContext(
            inspectorControllerID: ObjectIdentifier(inspectorContext.inspectorController)
        )

        if lastAppliedContext == appliedContext {
            return
        }

        if let inspectorContainer {
            inspectorContainer.willMove(toParent: nil)
            inspectorContainer.view.removeFromSuperview()
            inspectorContainer.removeFromParent()
        }

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
        inspectorContainer = container
        lastAppliedContext = appliedContext
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

import SwiftUI

#if canImport(UIKit)
import UIKit
import WebInspectorKit

struct BrowserInspectorWindowSceneView: View {
    var body: some View {
        BrowserInspectorWindowControllerRepresentable()
            .onContinueUserActivity(BrowserInspectorCoordinator.inspectorWindowSceneActivityType) { _ in }
    }
}

private struct BrowserInspectorWindowControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrowserInspectorWindowHostingController {
        BrowserInspectorWindowHostingController()
    }

    func updateUIViewController(_ uiViewController: BrowserInspectorWindowHostingController, context: Context) {
        uiViewController.updateInspectorContext()
    }
}

@MainActor
private final class BrowserInspectorWindowHostingController: UIViewController {
    private struct AppliedInspectorContext: Equatable {
        let inspectorControllerID: ObjectIdentifier
        let pageWebViewID: ObjectIdentifier
        let tabIdentifiers: [String]
    }

    private var inspectorContainer: WITabViewController?
    private var disconnectObserver: NSObjectProtocol?
    private var observedSceneIdentifier: String?
    private let placeholderLabel = UILabel()
    private var lastAppliedContext: AppliedInspectorContext?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        placeholderLabel.text = "Inspector unavailable"
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        updateInspectorContext()
    }

    isolated deinit {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attachSceneObserverIfNeeded()
    }

    func updateInspectorContext() {
        guard let inspectorContext = BrowserInspectorCoordinator.inspectorWindowContext() else {
            lastAppliedContext = nil
            if inspectorContainer == nil {
                installPlaceholderIfNeeded()
            }
            return
        }

        let pageWebView = inspectorContext.browserStore.webView
        let appliedContext = AppliedInspectorContext(
            inspectorControllerID: ObjectIdentifier(inspectorContext.inspectorController),
            pageWebViewID: ObjectIdentifier(pageWebView),
            tabIdentifiers: inspectorContext.tabs.map(\.identifier)
        )

        if lastAppliedContext == appliedContext {
            return
        }

        if let inspectorContainer {
            inspectorContainer.setInspectorController(inspectorContext.inspectorController)
            inspectorContainer.setPageWebView(pageWebView)
            inspectorContainer.setTabs(inspectorContext.tabs)
            lastAppliedContext = appliedContext
            return
        }

        placeholderLabel.removeFromSuperview()
        let container = WITabViewController(
            inspectorContext.inspectorController,
            webView: pageWebView,
            tabs: inspectorContext.tabs
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

    private func attachSceneObserverIfNeeded() {
        guard let windowScene = view.window?.windowScene else {
            return
        }

        let persistentIdentifier = windowScene.session.persistentIdentifier
        guard observedSceneIdentifier != persistentIdentifier else {
            return
        }

        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }

        observedSceneIdentifier = persistentIdentifier
        BrowserInspectorCoordinator.attachInspectorWindowSceneSession(windowScene.session)
        let sceneSession = windowScene.session
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: windowScene,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                BrowserInspectorCoordinator.handleInspectorWindowSceneDidDisconnect(sceneSession)
            }
        }
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

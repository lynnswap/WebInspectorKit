#if canImport(AppKit)
import AppKit
import WebKit
import WebInspectorCore
import WebInspectorUI

@MainActor
public final class WINetworkContainerViewController: NSViewController {
    public private(set) var sessionController: WISessionController

    private let embeddedViewController: WebInspectorUI.WINetworkViewController

    public var store: WINetworkStore {
        sessionController.networkStore
    }

    public init(configuration: WISessionConfiguration = .init()) {
        let sessionController = WISessionController(configuration: configuration)
        self.sessionController = sessionController
        self.embeddedViewController = WebInspectorUI.WINetworkViewController(
            store: sessionController.networkStore
        )
        super.init(nibName: nil, bundle: nil)
        sessionController.configurePanels([WITab.network().configuration])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        Task { @MainActor [sessionController] in
            sessionController.disconnect()
        }
    }

    public override func loadView() {
        view = NSView(frame: .zero)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        embedNetworkViewControllerIfNeeded()
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        sessionController.activateFromUIIfPossible()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        if WIAppKitBridge.window(for: view) == nil {
            sessionController.suspend()
        }
    }

    public func connect(to webView: WKWebView?) {
        sessionController.connect(to: webView)
    }

    public func suspend() {
        sessionController.suspend()
    }

    public func disconnect() {
        sessionController.disconnect()
    }

    private func embedNetworkViewControllerIfNeeded() {
        guard embeddedViewController.parent == nil else {
            return
        }

        addChild(embeddedViewController)
        let childView = embeddedViewController.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
#endif

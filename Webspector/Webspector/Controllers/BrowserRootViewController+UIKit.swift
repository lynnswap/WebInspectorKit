#if canImport(UIKit)
import UIKit
@_spi(Webspector) import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    private enum InspectorSessionState {
        case connected
        case suspended
        case disconnected
    }

    let store: BrowserStore
    let inspectorController: WIInspectorController
    let launchConfiguration: BrowserLaunchConfiguration
    private var pendingInspectorSessionState: InspectorSessionState?
    private var inspectorLifecycleTask: Task<Void, Never>?
    private var isFinalizingInspectorSession = false

    init(
        store: BrowserStore? = nil,
        inspectorController: WIInspectorController? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedStore = store ?? BrowserStore(
            url: launchConfiguration.initialURL,
            automaticallyLoadsInitialRequest: false
        )
        let resolvedInspectorController = inspectorController ?? WIInspectorController()

        self.store = resolvedStore
        self.inspectorController = resolvedInspectorController
        self.launchConfiguration = launchConfiguration

        let pageViewController = BrowserPageViewController(
            store: resolvedStore,
            inspectorController: resolvedInspectorController,
            launchConfiguration: launchConfiguration
        )

        super.init(rootViewController: pageViewController)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = false
        setNavigationBarHidden(false, animated: false)
        view.backgroundColor = .systemBackground
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(false, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestInspectorSessionState(.connected)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        requestInspectorSessionState(.suspended)
    }

    isolated deinit {
        inspectorLifecycleTask?.cancel()
        inspectorController.tearDownForDeinit()
    }

    func finalizeInspectorSession() {
        guard isFinalizingInspectorSession == false else {
            return
        }
        isFinalizingInspectorSession = true
        requestInspectorSessionState(.disconnected)
    }

    var pageViewControllerForTesting: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }
}

private extension BrowserRootViewController {
    func requestInspectorSessionState(_ state: InspectorSessionState) {
        if isFinalizingInspectorSession, state != .disconnected {
            return
        }
        pendingInspectorSessionState = state
        guard inspectorLifecycleTask == nil else {
            return
        }

        let inspectorController = inspectorController
        let store = store
        inspectorLifecycleTask = Task { [weak self, inspectorController, store] in
            guard let self else {
                return
            }
            defer {
                self.inspectorLifecycleTask = nil
            }

            while let desiredState = self.pendingInspectorSessionState {
                self.pendingInspectorSessionState = nil

                switch desiredState {
                case .connected:
                    await inspectorController.applyHostState(pageWebView: store.webView, visibility: .visible)
                case .suspended:
                    await inspectorController.applyHostState(pageWebView: store.webView, visibility: .hidden)
                case .disconnected:
                    await inspectorController.finalize()
                }
            }
        }
    }
}
#endif

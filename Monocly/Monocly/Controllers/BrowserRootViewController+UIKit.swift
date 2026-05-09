#if canImport(UIKit)
import UIKit
@_spi(Monocly) import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    private enum InspectorRuntimeAttachment {
        case attached
        case suspended
        case detached
    }

    let store: BrowserStore
    let inspectorRuntime: WIRuntimeSession
    let launchConfiguration: BrowserLaunchConfiguration
    private var pendingInspectorRuntimeAttachment: InspectorRuntimeAttachment?
    private var inspectorLifecycleTask: Task<Void, Never>?
    private var isFinalizingInspectorSession = false
    private var isPreservingInspectorSessionForSceneDisconnection = false

    init(
        store: BrowserStore? = nil,
        inspectorRuntime: WIRuntimeSession? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedStore = store ?? BrowserStore(
            url: launchConfiguration.initialURL,
            automaticallyLoadsInitialRequest: false
        )
        let resolvedInspectorRuntime = inspectorRuntime ?? WIRuntimeSession()

        self.store = resolvedStore
        self.inspectorRuntime = resolvedInspectorRuntime
        self.launchConfiguration = launchConfiguration

        let pageViewController = BrowserPageViewController(
            store: resolvedStore,
            inspectorRuntime: resolvedInspectorRuntime,
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
        view.backgroundColor = .clear
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(false, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPreservingInspectorSessionForSceneDisconnection = false
        requestInspectorRuntimeAttachment(.attached)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if launchConfiguration.uiTestScenario == .domRemoteURL {
            return
        }
        if pageViewController?.isPresentingInspectorForRuntimeAttachment == true {
            return
        }
        if isPreservingInspectorSessionForSceneDisconnection {
            return
        }
        requestInspectorRuntimeAttachment(.detached)
    }

    isolated deinit {
        inspectorLifecycleTask?.cancel()
    }

    func finalizeInspectorSession() {
        guard isFinalizingInspectorSession == false else {
            return
        }
        isFinalizingInspectorSession = true
        isPreservingInspectorSessionForSceneDisconnection = false
        requestInspectorRuntimeAttachment(.detached)
    }

    func prepareForSceneDisconnectionPreservingInspectorSession() {
        isPreservingInspectorSessionForSceneDisconnection = true
        requestInspectorRuntimeAttachment(.suspended)
    }

    func waitForInspectorSessionTransitions() async {
        while let inspectorLifecycleTask {
            await inspectorLifecycleTask.value
            if self.inspectorLifecycleTask == nil {
                break
            }
        }
    }

    private var pageViewController: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }

    var pageViewControllerForTesting: BrowserPageViewController? {
        pageViewController
    }
}

private extension BrowserRootViewController {
    private func requestInspectorRuntimeAttachment(_ attachment: InspectorRuntimeAttachment) {
        if isFinalizingInspectorSession, attachment != .detached {
            return
        }
        pendingInspectorRuntimeAttachment = attachment
        guard inspectorLifecycleTask == nil else {
            return
        }

        let inspectorRuntime = inspectorRuntime
        let store = store
        inspectorLifecycleTask = Task { [weak self, inspectorRuntime, store] in
            guard let self else {
                return
            }
            defer {
                self.inspectorLifecycleTask = nil
            }

            while let desiredAttachment = self.pendingInspectorRuntimeAttachment {
                self.pendingInspectorRuntimeAttachment = nil

                switch desiredAttachment {
                case .attached:
                    await inspectorRuntime.attach(to: store.webView)
                case .suspended:
                    await inspectorRuntime.suspendPageAttachment()
                case .detached:
                    await inspectorRuntime.detach()
                }
            }
        }
    }
}
#endif

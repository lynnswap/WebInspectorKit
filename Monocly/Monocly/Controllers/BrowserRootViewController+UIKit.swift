#if canImport(UIKit)
import UIKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    private enum InspectorSessionAttachment {
        case attached
        case detached
    }

    let store: BrowserStore
    let inspectorSession: WebInspectorSession
    let launchConfiguration: BrowserLaunchConfiguration
    private var resolvedInspectorSessionAttachment: InspectorSessionAttachment = .detached
    private var pendingInspectorSessionAttachment: InspectorSessionAttachment?
    private var inspectorLifecycleTask: Task<Void, Never>?
    private var isFinalizingInspectorSession = false
    private var isPreservingInspectorSessionForSceneDisconnection = false

    init(
        store: BrowserStore? = nil,
        inspectorSession: WebInspectorSession? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedStore = store ?? BrowserStore(
            url: launchConfiguration.initialURL,
            automaticallyLoadsInitialRequest: false
        )
        let resolvedInspectorSession = inspectorSession ?? WebInspectorSession()

        self.store = resolvedStore
        self.inspectorSession = resolvedInspectorSession
        self.launchConfiguration = launchConfiguration

        let pageViewController = BrowserPageViewController(
            store: resolvedStore,
            inspectorSession: resolvedInspectorSession,
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

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isPreservingInspectorSessionForSceneDisconnection = false
        requestInspectorSessionAttachment(.attached)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if pageViewController?.isPresentingInspectorForSessionAttachment == true {
            return
        }
        if isPreservingInspectorSessionForSceneDisconnection {
            return
        }
        requestInspectorSessionAttachment(.detached)
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
        requestInspectorSessionAttachment(.detached)
    }

    func prepareForSceneDisconnectionPreservingInspectorSession() {
        isPreservingInspectorSessionForSceneDisconnection = true
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

}

private extension BrowserRootViewController {
    private func requestInspectorSessionAttachment(_ attachment: InspectorSessionAttachment) {
        if isFinalizingInspectorSession, attachment != .detached {
            return
        }
        guard resolvedInspectorSessionAttachment != attachment
            || pendingInspectorSessionAttachment != nil
            || inspectorLifecycleTask != nil else {
            return
        }
        pendingInspectorSessionAttachment = attachment
        guard inspectorLifecycleTask == nil else {
            return
        }

        let inspectorSession = inspectorSession
        let store = store
        inspectorLifecycleTask = Task { [weak self, inspectorSession, store] in
            guard let self else {
                return
            }
            defer {
                self.inspectorLifecycleTask = nil
            }

            while let desiredAttachment = self.pendingInspectorSessionAttachment {
                self.pendingInspectorSessionAttachment = nil

                switch desiredAttachment {
                case .attached:
                    guard self.resolvedInspectorSessionAttachment != .attached else {
                        continue
                    }
                    do {
                        try await inspectorSession.attach(to: store.webView)
                        self.resolvedInspectorSessionAttachment = .attached
                    } catch {
                        continue
                    }
                case .detached:
                    guard self.resolvedInspectorSessionAttachment != .detached else {
                        continue
                    }
                    await inspectorSession.detach()
                    self.resolvedInspectorSessionAttachment = .detached
                }
            }
        }
    }
}
#endif

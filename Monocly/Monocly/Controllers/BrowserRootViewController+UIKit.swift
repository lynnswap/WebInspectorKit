#if canImport(UIKit)
import UIKit
import WebKit
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
    private var desiredInspectorSessionAttachment: InspectorSessionAttachment = .detached
    private var resolvedInspectorSessionAttachment: InspectorSessionAttachment = .detached
    private var pendingInspectorSessionAttachment: InspectorSessionAttachment?
    private var inspectorLifecycleTask: Task<Void, Never>?
    private var isFinalizingInspectorSession = false
    private var isPreservingInspectorSessionForSceneDisconnection = false
    private weak var attachedWebView: WKWebView?
    var onSelectedWebViewInstalledForTesting: ((WKWebView) -> Void)?
    var onAttachInspectorSessionForTesting: ((WKWebView) -> Void)?

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

        pageViewController.onSelectedWebViewInstalled = { [weak self] webView in
            self?.onSelectedWebViewInstalledForTesting?(webView)
            self?.selectedWebViewDidChange(to: webView)
        }
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

    func setInspectorSessionAttachedForTesting(to webView: WKWebView) {
        desiredInspectorSessionAttachment = .attached
        resolvedInspectorSessionAttachment = .attached
        attachedWebView = webView
    }

}

private extension BrowserRootViewController {
    private func selectedWebViewDidChange(to webView: WKWebView) {
        guard desiredInspectorSessionAttachment == .attached else {
            return
        }
        guard attachedWebView !== webView || inspectorLifecycleTask != nil else {
            return
        }
        requestInspectorSessionAttachment(.attached)
    }

    private func requestInspectorSessionAttachment(_ attachment: InspectorSessionAttachment) {
        if isFinalizingInspectorSession, attachment != .detached {
            return
        }
        desiredInspectorSessionAttachment = attachment

        let attachmentIsResolved = switch attachment {
        case .attached:
            resolvedInspectorSessionAttachment == .attached && attachedWebView === store.webView
        case .detached:
            resolvedInspectorSessionAttachment == .detached
        }
        guard attachmentIsResolved == false
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
                    let webView = store.webView
                    guard self.resolvedInspectorSessionAttachment != .attached
                        || self.attachedWebView !== webView else {
                        continue
                    }
                    do {
                        self.onAttachInspectorSessionForTesting?(webView)
                        try await inspectorSession.attach(to: webView)
                        self.resolvedInspectorSessionAttachment = .attached
                        self.attachedWebView = webView
                    } catch {
                        self.resolvedInspectorSessionAttachment = .detached
                        self.attachedWebView = nil
                        continue
                    }
                case .detached:
                    guard self.resolvedInspectorSessionAttachment != .detached else {
                        continue
                    }
                    await inspectorSession.detach()
                    self.resolvedInspectorSessionAttachment = .detached
                    self.attachedWebView = nil
                }
            }
        }
    }
}
#endif

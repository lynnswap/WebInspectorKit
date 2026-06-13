#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorKit

@MainActor
private final class BrowserInspectorSessionAttachmentLifecycle {
    enum Attachment {
        case attached
        case detached
    }

    private let store: BrowserStore
    private let inspectorSession: WebInspectorSession
    private var desiredAttachment: Attachment = .detached
    private var resolvedAttachment: Attachment = .detached
    private var pendingAttachment: Attachment?
    private var lifecycleTask: Task<Void, Never>?
    private var isFinalizing = false
    private weak var attachedWebView: WKWebView?
    var onAttachForTesting: ((WKWebView) -> Void)?

    init(
        store: BrowserStore,
        inspectorSession: WebInspectorSession
    ) {
        self.store = store
        self.inspectorSession = inspectorSession
    }

    func cancel() {
        lifecycleTask?.cancel()
    }

    func finalize() -> Bool {
        guard isFinalizing == false else {
            return false
        }
        isFinalizing = true
        request(.detached)
        return true
    }

    func waitForTransitions() async {
        while let lifecycleTask {
            await lifecycleTask.value
            if self.lifecycleTask == nil {
                break
            }
        }
    }

    func setAttachedForTesting(to webView: WKWebView) {
        desiredAttachment = .attached
        resolvedAttachment = .attached
        attachedWebView = webView
    }

    func selectedWebViewDidChange(to webView: WKWebView) {
        guard desiredAttachment == .attached else {
            return
        }
        guard attachedWebView !== webView || lifecycleTask != nil else {
            return
        }
        request(.attached)
    }

    func request(_ attachment: Attachment) {
        if isFinalizing, attachment != .detached {
            return
        }
        desiredAttachment = attachment

        guard isResolved(attachment) == false
            || pendingAttachment != nil
            || lifecycleTask != nil else {
            return
        }
        pendingAttachment = attachment
        startLifecycleTaskIfNeeded()
    }

    private func isResolved(_ attachment: Attachment) -> Bool {
        switch attachment {
        case .attached:
            resolvedAttachment == .attached && attachedWebView === store.webView
        case .detached:
            resolvedAttachment == .detached
        }
    }

    private func startLifecycleTaskIfNeeded() {
        guard lifecycleTask == nil else {
            return
        }

        let inspectorSession = inspectorSession
        let store = store
        lifecycleTask = Task { [weak self, inspectorSession, store] in
            guard let self else {
                return
            }
            defer {
                self.lifecycleTask = nil
            }

            while let desiredAttachment = self.pendingAttachment {
                self.pendingAttachment = nil

                switch desiredAttachment {
                case .attached:
                    let webView = store.webView
                    guard self.resolvedAttachment != .attached
                        || self.attachedWebView !== webView else {
                        continue
                    }
                    do {
                        self.onAttachForTesting?(webView)
                        try await inspectorSession.attach(to: webView)
                        self.resolvedAttachment = .attached
                        self.attachedWebView = webView
                    } catch {
                        self.resolvedAttachment = .detached
                        self.attachedWebView = nil
                        continue
                    }
                case .detached:
                    guard self.resolvedAttachment != .detached else {
                        continue
                    }
                    await inspectorSession.detach()
                    self.resolvedAttachment = .detached
                    self.attachedWebView = nil
                }
            }
        }
    }
}

@MainActor
final class BrowserRootViewController: UINavigationController {
    let store: BrowserStore
    let inspectorSession: WebInspectorSession
    let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorSessionAttachmentLifecycle: BrowserInspectorSessionAttachmentLifecycle
    private var isPreservingInspectorSessionForSceneDisconnection = false
    var onSelectedWebViewInstalledForTesting: ((WKWebView) -> Void)?
    var onAttachInspectorSessionForTesting: ((WKWebView) -> Void)? {
        get {
            inspectorSessionAttachmentLifecycle.onAttachForTesting
        }
        set {
            inspectorSessionAttachmentLifecycle.onAttachForTesting = newValue
        }
    }

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
        self.inspectorSessionAttachmentLifecycle = BrowserInspectorSessionAttachmentLifecycle(
            store: resolvedStore,
            inspectorSession: resolvedInspectorSession
        )

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
        inspectorSessionAttachmentLifecycle.request(.attached)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if pageViewController?.isPresentingInspectorForSessionAttachment == true {
            return
        }
        if isPreservingInspectorSessionForSceneDisconnection {
            return
        }
        inspectorSessionAttachmentLifecycle.request(.detached)
    }

    isolated deinit {
        inspectorSessionAttachmentLifecycle.cancel()
    }

    func finalizeInspectorSession() {
        guard inspectorSessionAttachmentLifecycle.finalize() else {
            return
        }
        isPreservingInspectorSessionForSceneDisconnection = false
    }

    func prepareForSceneDisconnectionPreservingInspectorSession() {
        isPreservingInspectorSessionForSceneDisconnection = true
    }

    func waitForInspectorSessionTransitions() async {
        await inspectorSessionAttachmentLifecycle.waitForTransitions()
    }

    private var pageViewController: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }

    func setInspectorSessionAttachedForTesting(to webView: WKWebView) {
        inspectorSessionAttachmentLifecycle.setAttachedForTesting(to: webView)
    }

}

private extension BrowserRootViewController {
    private func selectedWebViewDidChange(to webView: WKWebView) {
        inspectorSessionAttachmentLifecycle.selectedWebViewDidChange(to: webView)
    }
}
#endif

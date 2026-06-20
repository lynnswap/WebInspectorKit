#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    let browserWindow: BrowserWindow
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
        browserWindow: BrowserWindow? = nil,
        inspectorSession: WebInspectorSession? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedBrowserWindow = browserWindow ?? BrowserWindow(
            initialState: .fresh(
                url: launchConfiguration.initialURL,
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let resolvedInspectorSession = inspectorSession ?? WebInspectorSession()

        self.browserWindow = resolvedBrowserWindow
        self.inspectorSession = resolvedInspectorSession
        self.launchConfiguration = launchConfiguration
        self.inspectorSessionAttachmentLifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: resolvedBrowserWindow,
            inspectorSession: resolvedInspectorSession
        )

        let pageViewController = BrowserPageViewController(
            browserWindow: resolvedBrowserWindow,
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

#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    let browserWindow: BrowserWindow
    let inspector: WebInspector
    let launchConfiguration: BrowserLaunchConfiguration
    private let inspectorAttachmentLifecycle: BrowserInspectorAttachmentLifecycle
    private var isPreservingInspectorSessionForSceneDisconnection = false
    var onSelectedWebViewInstalledForTesting: ((WKWebView) -> Void)?

    init(
        browserWindow: BrowserWindow? = nil,
        inspector: WebInspector? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedBrowserWindow = browserWindow ?? BrowserWindow(
            initialState: .fresh(
                url: launchConfiguration.initialURL,
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let resolvedInspector = inspector ?? WebInspector()

        self.browserWindow = resolvedBrowserWindow
        self.inspector = resolvedInspector
        self.launchConfiguration = launchConfiguration
        self.inspectorAttachmentLifecycle = BrowserInspectorAttachmentLifecycle(
            browserWindow: resolvedBrowserWindow,
            inspector: resolvedInspector
        )

        let pageViewController = BrowserPageViewController(
            browserWindow: resolvedBrowserWindow,
            inspector: resolvedInspector,
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
        inspectorAttachmentLifecycle.request(.attached)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if pageViewController?.isPresentingInspectorForSessionAttachment == true {
            return
        }
        if isPreservingInspectorSessionForSceneDisconnection {
            return
        }
        inspectorAttachmentLifecycle.request(.detached)
    }

    isolated deinit {
        inspectorAttachmentLifecycle.cancel()
    }

    func finalizeInspectorSession() {
        guard inspectorAttachmentLifecycle.finalize() else {
            return
        }
        isPreservingInspectorSessionForSceneDisconnection = false
    }

    func prepareForSceneDisconnectionPreservingInspectorSession() {
        isPreservingInspectorSessionForSceneDisconnection = true
    }

    func waitForInspectorSessionTransitions() async {
        await inspectorAttachmentLifecycle.waitForTransitions()
    }

    private var pageViewController: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }

    func setInspectorSessionAttachedForTesting(to webView: WKWebView) {
        inspectorAttachmentLifecycle.setAttachedForTesting(to: webView)
    }

}

private extension BrowserRootViewController {
    private func selectedWebViewDidChange(to webView: WKWebView) {
        inspectorAttachmentLifecycle.selectedWebViewDidChange(to: webView)
    }
}
#endif

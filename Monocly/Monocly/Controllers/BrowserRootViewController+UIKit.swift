#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    let browserWindow: BrowserWindow
    let inspector: WebInspector
    let launchConfiguration: BrowserLaunchConfiguration
    /// Set when the window is closing. The inspector is not attached again.
    private var isInspectorFinalized = false
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
        attachInspector(to: browserWindow.webView)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if pageViewController?.isPresentingInspectorForSessionAttachment == true {
            return
        }
        if isPreservingInspectorSessionForSceneDisconnection {
            return
        }
        detachInspector()
    }

    /// Ends the inspection for good when the window closes.
    func finalizeInspectorSession() {
        guard isInspectorFinalized == false else {
            return
        }
        isInspectorFinalized = true
        isPreservingInspectorSessionForSceneDisconnection = false
        detachInspector()
    }

    func prepareForSceneDisconnectionPreservingInspectorSession() {
        isPreservingInspectorSessionForSceneDisconnection = true
    }

    /// Suspends until the inspector has finished attaching or detaching.
    func waitForInspectorSessionTransitions() async {
        await inspector.waitUntilSettled()
    }

    private var pageViewController: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }

}

private extension BrowserRootViewController {
    /// Follows the selected tab while the inspector is in use.
    private func selectedWebViewDidChange(to webView: WKWebView) {
        guard inspector.inspectedWebView != nil else {
            return
        }
        attachInspector(to: webView)
    }

    /// `WebInspector` orders the calls itself: it ends the current attachment
    /// before it starts the next one, and does nothing for the web view that
    /// it already inspects.
    private func attachInspector(to webView: WKWebView) {
        guard isInspectorFinalized == false else {
            return
        }
        inspector.attach(to: webView)
    }

    private func detachInspector() {
        guard inspector.inspectedWebView != nil else {
            return
        }
        inspector.detach()
    }
}

private extension WebInspector {
    /// Suspends until the inspector has finished attaching or detaching, or
    /// until the calling task is cancelled.
    func waitUntilSettled() async {
        while state == .attaching || state == .detaching, Task.isCancelled == false {
            let waiter = StateChangeWaiter()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiter.continuation = continuation
                    withObservationTracking {
                        _ = state
                    } onChange: {
                        Task { @MainActor in
                            waiter.resume()
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    waiter.resume()
                }
            }
        }
    }
}

@MainActor
private final class StateChangeWaiter {
    var continuation: CheckedContinuation<Void, Never>?

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
#endif

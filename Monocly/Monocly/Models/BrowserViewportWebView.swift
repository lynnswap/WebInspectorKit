import UIKit
import WebKit
import WKViewportCoordinator

typealias BrowserPlatformColor = UIColor
typealias BrowserViewportCoordinator = ViewportCoordinator

@MainActor
final class BrowserViewportWebView: WKWebView {
    weak var viewportCoordinator: BrowserViewportCoordinator?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        viewportCoordinator?.webViewHierarchyDidChange()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        viewportCoordinator?.webViewHierarchyDidChange()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        viewportCoordinator?.webViewSafeAreaInsetsDidChange()
    }
}

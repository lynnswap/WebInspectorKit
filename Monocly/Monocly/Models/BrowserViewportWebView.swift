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
        viewportCoordinator?.update()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        viewportCoordinator?.update()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        viewportCoordinator?.update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        viewportCoordinator?.update()
    }
}

#if os(iOS)
@_exported import WKViewportCoordinator
#elseif canImport(UIKit)
import UIKit
import WebKit

public enum BottomChromeMode: Equatable {
    case normal
    case hiddenForKeyboard
}

public enum ScrollEdgeEffectStyle: Equatable {
    case automatic
    case hard
    case soft
}

public struct ViewportConfiguration: Equatable {
    public var contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior
    public var topEdgeEffectHidden: Bool
    public var bottomEdgeEffectHidden: Bool
    public var topEdgeEffectStyle: ScrollEdgeEffectStyle
    public var bottomEdgeEffectStyle: ScrollEdgeEffectStyle
    public var safeAreaAffectedEdges: UIRectEdge

    public init(
        contentInsetAdjustmentBehavior: UIScrollView.ContentInsetAdjustmentBehavior = .always,
        topEdgeEffectHidden: Bool = false,
        bottomEdgeEffectHidden: Bool = false,
        topEdgeEffectStyle: ScrollEdgeEffectStyle = .soft,
        bottomEdgeEffectStyle: ScrollEdgeEffectStyle = .soft,
        safeAreaAffectedEdges: UIRectEdge = [.top, .bottom]
    ) {
        self.contentInsetAdjustmentBehavior = contentInsetAdjustmentBehavior
        self.topEdgeEffectHidden = topEdgeEffectHidden
        self.bottomEdgeEffectHidden = bottomEdgeEffectHidden
        self.topEdgeEffectStyle = topEdgeEffectStyle
        self.bottomEdgeEffectStyle = bottomEdgeEffectStyle
        self.safeAreaAffectedEdges = safeAreaAffectedEdges
    }
}

@MainActor
public final class ViewportCoordinator: NSObject {
    public weak var hostViewController: UIViewController?
    public weak var webView: WKWebView?
    public var configuration: ViewportConfiguration

    public init(
        hostViewController: UIViewController? = nil,
        webView: WKWebView,
        configuration: ViewportConfiguration = .init()
    ) {
        self.hostViewController = hostViewController
        self.webView = webView
        self.configuration = configuration
        super.init()
    }

    public convenience init(
        webView: WKWebView,
        configuration: ViewportConfiguration = .init()
    ) {
        self.init(
            hostViewController: nil,
            webView: webView,
            configuration: configuration
        )
    }

    public func invalidate() {}
    public func handleViewDidAppear() {}
    public func handleWebViewHierarchyDidChange() {}
    public func handleWebViewSafeAreaInsetsDidChange() {}
    public func updateViewport() {}
}

@MainActor
public final class ManagedViewportWebView: WKWebView {
    public weak var viewportHostViewController: UIViewController?
    public var viewportConfiguration = ViewportConfiguration()
}
#endif

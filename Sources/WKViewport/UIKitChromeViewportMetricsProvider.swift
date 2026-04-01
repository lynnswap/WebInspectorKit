#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class UIKitChromeViewportMetricsProvider: ViewportMetricsProvider {
    public init() {}

    public func makeViewportMetrics(
        in hostViewController: UIViewController,
        webView: WKWebView,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat
    ) -> ViewportMetrics {
        let viewportHostView = webView.superview ?? hostViewController.viewIfLoaded
        let safeAreaInsets = projectedWindowSafeAreaInsets(in: viewportHostView)
        let topOverlap = topChromeObscuredHeight(in: hostViewController, hostView: viewportHostView)
        let bottomOverlap = bottomChromeObscuredHeight(in: hostViewController, hostView: viewportHostView)

        return ViewportMetrics(
            safeAreaInsets: safeAreaInsets,
            topObscuredHeight: topOverlap,
            bottomObscuredHeight: bottomOverlap,
            keyboardOverlapHeight: keyboardOverlapHeight,
            inputAccessoryOverlapHeight: inputAccessoryOverlapHeight,
            bottomChromeMode: .normal
        )
    }

    private func projectedWindowSafeAreaInsets(in hostView: UIView?) -> UIEdgeInsets {
        guard let hostView, let window = hostView.window else {
            return .zero
        }

        let hostRectInWindow = hostView.convert(hostView.bounds, to: window)
        let safeRectInWindow = window.bounds.inset(by: window.safeAreaInsets)

        return UIEdgeInsets(
            top: max(0, safeRectInWindow.minY - hostRectInWindow.minY),
            left: max(0, safeRectInWindow.minX - hostRectInWindow.minX),
            bottom: max(0, hostRectInWindow.maxY - safeRectInWindow.maxY),
            right: max(0, hostRectInWindow.maxX - safeRectInWindow.maxX)
        )
    }

    private func topChromeObscuredHeight(
        in hostViewController: UIViewController,
        hostView: UIView?
    ) -> CGFloat {
        topEdgeObscuredHeight(
            of: hostViewController.navigationController?.navigationBar,
            in: hostView
        )
    }

    private func bottomChromeObscuredHeight(
        in hostViewController: UIViewController,
        hostView: UIView?
    ) -> CGFloat {
        let tabBarOverlap = bottomEdgeObscuredHeight(
            of: hostViewController.tabBarController?.tabBar,
            in: hostView
        )
        let toolbarOverlap = bottomEdgeObscuredHeight(
            of: resolvedVisibleToolbar(for: hostViewController),
            in: hostView
        )
        return max(tabBarOverlap, toolbarOverlap)
    }

    private func resolvedVisibleToolbar(for hostViewController: UIViewController) -> UIToolbar? {
        guard let navigationController = hostViewController.navigationController else {
            return nil
        }
        guard navigationController.isToolbarHidden == false else {
            return nil
        }
        return navigationController.toolbar
    }

    private func topEdgeObscuredHeight(of chromeView: UIView?, in hostView: UIView?) -> CGFloat {
        guard let chromeView, let hostView else {
            return 0
        }
        guard let window = hostView.window, chromeView.window != nil else {
            return 0
        }
        guard chromeView.isHidden == false, effectiveAlpha(of: chromeView) > 0 else {
            return 0
        }

        let hostFrameInWindow = hostView.convert(hostView.bounds, to: window)
        let chromeFrameInWindow = chromeView.convert(chromeView.bounds, to: window)
        guard hostFrameInWindow.intersects(chromeFrameInWindow) || chromeFrameInWindow.maxY > hostFrameInWindow.minY else {
            return 0
        }

        return max(0, min(hostFrameInWindow.maxY, chromeFrameInWindow.maxY) - hostFrameInWindow.minY)
    }

    private func bottomEdgeObscuredHeight(of chromeView: UIView?, in hostView: UIView?) -> CGFloat {
        guard let chromeView, let hostView else {
            return 0
        }
        guard let window = hostView.window, chromeView.window != nil else {
            return 0
        }
        guard chromeView.isHidden == false, effectiveAlpha(of: chromeView) > 0 else {
            return 0
        }

        let hostFrameInWindow = hostView.convert(hostView.bounds, to: window)
        let chromeFrameInWindow = chromeView.convert(chromeView.bounds, to: window)
        guard hostFrameInWindow.intersects(chromeFrameInWindow) || chromeFrameInWindow.minY < hostFrameInWindow.maxY else {
            return 0
        }

        return max(0, hostFrameInWindow.maxY - max(hostFrameInWindow.minY, chromeFrameInWindow.minY))
    }

    private func effectiveAlpha(of view: UIView) -> CGFloat {
        var alpha = view.alpha
        var currentSuperview = view.superview

        while let superview = currentSuperview {
            if superview.isHidden {
                return 0
            }
            alpha *= superview.alpha
            currentSuperview = superview.superview
        }

        return alpha
    }
}
#endif

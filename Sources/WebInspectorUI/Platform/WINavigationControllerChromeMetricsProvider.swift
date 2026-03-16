#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class WINavigationControllerChromeMetricsProvider: WIWebViewChromeMetricsProviding {
    public init() {}

    public func makeChromeMetrics(
        in hostViewController: UIViewController,
        webView: WKWebView,
        keyboardOverlapHeight: CGFloat,
        inputAccessoryOverlapHeight: CGFloat
    ) -> WIWebViewChromeMetrics {
        let safeAreaInsets = hostViewController.viewIfLoaded?.safeAreaInsets ?? .zero
        return WIWebViewChromeMetrics(
            safeAreaInsets: safeAreaInsets,
            topObscuredHeight: safeAreaInsets.top,
            bottomObscuredHeight: safeAreaInsets.bottom,
            keyboardOverlapHeight: keyboardOverlapHeight,
            inputAccessoryOverlapHeight: inputAccessoryOverlapHeight,
            bottomChromeMode: .normal
        )
    }
}
#endif

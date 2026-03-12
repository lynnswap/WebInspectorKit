import WebInspectorCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WIDOMPlatformBridge: WIDOMUIBridge {
    static let shared = WIDOMPlatformBridge()

#if canImport(UIKit)
    private var scrollBackupByWebViewID: [ObjectIdentifier: (isScrollEnabled: Bool, isPanEnabled: Bool)] = [:]
#endif

    private init() {}

    func prepareForSelection(using runtime: WIDOMRuntime) {
#if canImport(AppKit)
        focusPageWindowIfNeeded(using: runtime)
#endif
#if canImport(UIKit)
        disablePageScrolling(using: runtime)
#endif
    }

    func finishSelection(using runtime: WIDOMRuntime) {
#if canImport(UIKit)
        restorePageScrolling(using: runtime)
#endif
    }

    func copyToPasteboard(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#else
        _ = text
#endif
    }
}

#if canImport(AppKit)
private extension WIDOMPlatformBridge {
    func focusPageWindowIfNeeded(using runtime: WIDOMRuntime) {
        guard let pageWebView = runtime.pageWebView ?? runtime.lastPageWebView else {
            return
        }

        guard let pageWindow = unsafe pageWebView.window else {
            return
        }

        if NSApp.isActive == false {
            NSApp.activate(ignoringOtherApps: true)
        }
        pageWindow.makeKeyAndOrderFront(nil)
        if pageWindow.firstResponder !== pageWebView {
            pageWindow.makeFirstResponder(pageWebView)
        }
    }
}
#endif

#if canImport(UIKit)
private extension WIDOMPlatformBridge {
    func disablePageScrolling(using runtime: WIDOMRuntime) {
        guard let webView = runtime.pageWebView else {
            return
        }
        let webViewID = ObjectIdentifier(webView)
        let scrollView = webView.scrollView
        if scrollBackupByWebViewID[webViewID] == nil {
            scrollBackupByWebViewID[webViewID] = (
                scrollView.isScrollEnabled,
                scrollView.panGestureRecognizer.isEnabled
            )
        }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
    }

    func restorePageScrolling(using runtime: WIDOMRuntime) {
        guard let webView = runtime.pageWebView else {
            return
        }
        let webViewID = ObjectIdentifier(webView)
        let scrollView = webView.scrollView
        if let backup = scrollBackupByWebViewID[webViewID] {
            scrollView.isScrollEnabled = backup.isScrollEnabled
            scrollView.panGestureRecognizer.isEnabled = backup.isPanEnabled
            scrollBackupByWebViewID.removeValue(forKey: webViewID)
        }
    }
}
#endif

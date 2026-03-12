import WebInspectorDOM

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

    func prepareForSelection(using session: DOMSession) {
#if canImport(AppKit)
        focusPageWindowIfNeeded(using: session)
#endif
#if canImport(UIKit)
        disablePageScrolling(using: session)
#endif
    }

    func finishSelection(using session: DOMSession) {
#if canImport(UIKit)
        restorePageScrolling(using: session)
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
    func focusPageWindowIfNeeded(using session: DOMSession) {
        guard let pageWebView = session.pageWebView ?? session.lastPageWebView else {
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
    func disablePageScrolling(using session: DOMSession) {
        guard let webView = session.pageWebView else {
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

    func restorePageScrolling(using session: DOMSession) {
        guard let webView = session.pageWebView else {
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

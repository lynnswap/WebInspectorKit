#if canImport(UIKit)
import WebInspectorBridgeObjCShim
import WebKit

@MainActor
package enum WIInspectorSelectionPrivateBridge {
    package static func hasPrivateInspectorAccess(in webView: WKWebView) -> Bool {
        WIKRuntimeBridge.inspector(for: webView) != nil
    }

    package static func isElementSelectionActive(in webView: WKWebView) -> Bool? {
        WIKRuntimeBridge.inspectorElementSelectionActive(for: webView)?.boolValue
    }

    package static func setNodeSearchEnabled(
        _ enabled: Bool,
        in webView: WKWebView
    ) -> Bool {
        if enabled {
            return WIKRuntimeBridge.enableInspectorNodeSearch(for: webView)
        }
        return WIKRuntimeBridge.disableInspectorNodeSearch(for: webView)
    }

    package static func hasNodeSearchRecognizer(in webView: WKWebView) -> Bool {
        WIKRuntimeBridge.hasInspectorNodeSearchRecognizer(for: webView)
    }

    package static func removeNodeSearchRecognizers(in webView: WKWebView) -> Bool {
        WIKRuntimeBridge.removeInspectorNodeSearchRecognizers(from: webView)
    }
}
#endif

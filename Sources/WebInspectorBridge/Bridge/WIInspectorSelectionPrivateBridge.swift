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

    package static func isInspectorConnected(in webView: WKWebView) -> Bool? {
        WIKRuntimeBridge.inspectorConnected(for: webView)?.boolValue
    }

    package static func connectInspector(in webView: WKWebView) -> Bool {
        WIKRuntimeBridge.connectInspector(for: webView)
    }

    package static func toggleElementSelection(in webView: WKWebView) -> Bool {
        WIKRuntimeBridge.toggleInspectorElementSelection(for: webView)
    }

    package static func canEnableNodeSearch(in webView: WKWebView) -> Bool {
        WIKRuntimeBridge.canEnableInspectorNodeSearch(for: webView)
    }

    package static func isInspectorIndicationVisible(in webView: WKWebView) -> Bool? {
        WIKRuntimeBridge.showingInspectorIndication(for: webView)?.boolValue
    }

    package static func setInspectorIndicationVisible(
        _ visible: Bool,
        in webView: WKWebView
    ) -> Bool {
        WIKRuntimeBridge.setShowingInspectorIndication(visible, for: webView)
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

    package static func nodeSearchDebugSummary(in webView: WKWebView) -> String? {
        WIKRuntimeBridge.nodeSearchDebugSummary(for: webView)
    }
}
#endif

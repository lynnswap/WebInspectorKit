#if canImport(UIKit)
import Testing
@testable import WebInspectorProxyKit

@MainActor
@Test
func nativeInspectablePageReloadFailsWhenWebViewIsUnavailable() {
    let page = NativeInspectablePage(missingWebViewForTesting: ())

    #expect(page.canReload == false)
    do {
        try page.reload()
        Issue.record("Expected reload to fail when the inspected WKWebView is unavailable.")
    } catch {
        #expect(String(describing: error) == "Inspected WKWebView is no longer available.")
    }
}

#endif

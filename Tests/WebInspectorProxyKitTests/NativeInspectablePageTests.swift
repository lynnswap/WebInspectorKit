#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WebInspectorProxyKit

@MainActor
@Test
func nativeInspectablePageRestoresOriginalInspectability() {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false

    let page = NativeInspectablePage(webView: webView)

    #expect(webView.isInspectable == true)

    page.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == false)

    page.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func overlappingNativeInspectablePagesRestoreOnlyAfterLastOwner() {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false

    let firstPage = NativeInspectablePage(webView: webView)
    let secondPage = NativeInspectablePage(webView: webView)

    #expect(webView.isInspectable == true)

    secondPage.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == true)

    firstPage.restoreInspectabilityIfNeeded()

    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func droppingNativeInspectablePageRestoresInspectability() {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    var page: NativeInspectablePage? = NativeInspectablePage(webView: webView)

    #expect(webView.isInspectable)

    page = nil

    #expect(page == nil)
    #expect(webView.isInspectable == false)
}

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

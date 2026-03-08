import Testing
import WebKit
@testable import WebInspectorUI

#if canImport(AppKit)
import AppKit

@MainActor
struct WIDOMTreeViewControllerAppKitTests {
    @Test
    func embedsInspectorWebViewForPreview() {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        _ = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(inspector)
        let controller = WIDOMTreeViewController(inspector: inspector)

        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        #expect(findWebView(in: controller.view) != nil)
    }
}

@MainActor
private func findWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView {
        return webView
    }
    for subview in view.subviews {
        if let webView = findWebView(in: subview) {
            return webView
        }
    }
    return nil
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
struct WIDOMTreeViewControllerUIKitTests {
    @Test
    func embedsInspectorWebViewForPreview() {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        _ = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(inspector)
        let controller = WIDOMTreeViewController(inspector: inspector)

        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        #expect(findWebView(in: controller.view) != nil)
    }
}

@MainActor
private func findWebView(in view: UIView) -> WKWebView? {
    if let webView = view as? WKWebView {
        return webView
    }
    for subview in view.subviews {
        if let webView = findWebView(in: subview) {
            return webView
        }
    }
    return nil
}
#endif

import Testing
import WebKit
@testable import WebInspectorUI

#if canImport(AppKit)
import AppKit

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WIDOMTreeViewControllerAppKitTests {
    @Test
    func embedsInspectorWebViewForPreview() {
        let store = WIDOMPreviewFixtures.makeStore(mode: .selected)
        _ = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(store)
        let controller = WIDOMTreeViewController(store: store)

        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        #expect(findWebView(in: controller.view) != nil)
    }

    @Test
    func doesNotShowErrorOverlayWhenRecoverableErrorExists() async {
        let store = WIDOMPreviewFixtures.makeStore(mode: .empty)
        let controller = WIDOMTreeViewController(store: store)

        controller.loadViewIfNeeded()
        await store.reloadFrontend()

        #expect(controller.testShowsErrorLabel == false)
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
@Suite(.serialized, .webKitIsolated)
struct WIDOMTreeViewControllerUIKitTests {
    @Test
    func embedsInspectorWebViewForPreview() {
        let store = WIDOMPreviewFixtures.makeStore(mode: .selected)
        _ = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(store)
        let controller = WIDOMTreeViewController(store: store)

        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()

        #expect(findWebView(in: controller.view) != nil)
    }

    @Test
    func doesNotShowErrorOverlayWhenRecoverableErrorExists() async {
        let store = WIDOMPreviewFixtures.makeStore(mode: .empty)
        let controller = WIDOMTreeViewController(store: store)

        controller.loadViewIfNeeded()
        await store.reloadFrontend()

        #expect(controller.contentUnavailableConfiguration == nil)
        #expect(controller.navigationItem.prompt == nil)
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

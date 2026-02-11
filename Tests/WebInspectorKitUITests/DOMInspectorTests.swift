import Testing
import WebKit
import WebInspectorKitCore
@testable import WebInspectorKit

@MainActor
struct DOMInspectorTests {
    @Test
    func sharesSelectionInstanceWithSession() {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        #expect(inspector.selection === inspector.session.selection)
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        let webView = makeTestWebView()

        #expect(inspector.hasPageWebView == false)
        inspector.attach(to: webView)
        #expect(inspector.hasPageWebView == true)
        #expect(inspector.session.lastPageWebView === webView)

        inspector.detach()
        #expect(inspector.hasPageWebView == false)
        #expect(inspector.session.lastPageWebView == nil)
        #expect(inspector.selection.nodeId == nil)
    }

    @Test
    func attachSwitchingPageClearsPendingMutationBundles() {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        let firstWebView = makeTestWebView()
        let secondWebView = makeTestWebView()

        inspector.attach(to: firstWebView)
        inspector.frontendStore.enqueueMutationBundle("{\"kind\":\"test\"}", preserveState: true)
        #expect(inspector.frontendStore.pendingMutationBundleCount == 1)

        inspector.attach(to: secondWebView)

        #expect(inspector.session.lastPageWebView === secondWebView)
        #expect(inspector.frontendStore.pendingMutationBundleCount == 0)
    }

    @Test
    func reloadInspectorWithoutPageSetsErrorMessage() async {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        #expect(inspector.errorMessage == nil)

        await inspector.reloadInspector()

        #expect(inspector.errorMessage == String(localized: "dom.error.webview_unavailable", bundle: .module))
    }

    @Test
    func updateSnapshotDepthClampsAndUpdatesConfiguration() {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        inspector.updateSnapshotDepth(0)
        #expect(inspector.session.configuration.snapshotDepth == 1)

        inspector.updateSnapshotDepth(6)
        #expect(inspector.session.configuration.snapshotDepth == 6)
    }

    @Test
    func updateAndRemoveAttributeMutateSelectionState() {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        inspector.selection.nodeId = 7
        inspector.selection.attributes = [
            DOMAttribute(nodeId: 7, name: "class", value: "old"),
            DOMAttribute(nodeId: 7, name: "id", value: "foo")
        ]

        inspector.updateAttributeValue(name: "class", value: "new")
        #expect(inspector.selection.attributes.first(where: { $0.name == "class" })?.value == "new")

        inspector.removeAttribute(name: "id")
        #expect(inspector.selection.attributes.contains(where: { $0.name == "id" }) == false)
    }

    @Test
    func detachClearsErrorMessage() async {
        let controller = WebInspector.Controller()
        let inspector = controller.dom
        await inspector.reloadInspector()
        #expect(inspector.errorMessage != nil)

        inspector.detach()

        #expect(inspector.errorMessage == nil)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}

import Testing
import WebKit
@testable import WebInspectorKit

@MainActor
struct WIDOMViewModelTests {
    @Test
    func sharesSelectionInstanceWithSession() {
        let viewModel = WIDOMViewModel()
        #expect(viewModel.selection === viewModel.session.selection)
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() {
        let viewModel = WIDOMViewModel()
        let webView = makeTestWebView()

        #expect(viewModel.hasPageWebView == false)
        viewModel.attach(to: webView)
        #expect(viewModel.hasPageWebView == true)
        #expect(viewModel.session.lastPageWebView === webView)

        viewModel.detach()
        #expect(viewModel.hasPageWebView == false)
        #expect(viewModel.session.lastPageWebView == nil)
        #expect(viewModel.selection.nodeId == nil)
    }

    @Test
    func reloadInspectorWithoutPageSetsErrorMessage() async {
        let viewModel = WIDOMViewModel()
        #expect(viewModel.errorMessage == nil)

        await viewModel.reloadInspector()

        #expect(viewModel.errorMessage == "WebView is not available.")
    }

    @Test
    func updateSnapshotDepthClampsAndUpdatesConfiguration() {
        let viewModel = WIDOMViewModel()
        viewModel.updateSnapshotDepth(0)
        #expect(viewModel.session.configuration.snapshotDepth == 1)

        viewModel.updateSnapshotDepth(6)
        #expect(viewModel.session.configuration.snapshotDepth == 6)
    }

    @Test
    func updateAndRemoveAttributeMutateSelectionState() {
        let viewModel = WIDOMViewModel()
        viewModel.selection.nodeId = 7
        viewModel.selection.attributes = [
            WIDOMAttribute(nodeId: 7, name: "class", value: "old"),
            WIDOMAttribute(nodeId: 7, name: "id", value: "foo")
        ]

        viewModel.updateAttributeValue(name: "class", value: "new")
        #expect(viewModel.selection.attributes.first(where: { $0.name == "class" })?.value == "new")

        viewModel.removeAttribute(name: "id")
        #expect(viewModel.selection.attributes.contains(where: { $0.name == "id" }) == false)
    }

    @Test
    func detachClearsErrorMessage() async {
        let viewModel = WIDOMViewModel()
        await viewModel.reloadInspector()
        #expect(viewModel.errorMessage != nil)

        viewModel.detach()

        #expect(viewModel.errorMessage == nil)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}

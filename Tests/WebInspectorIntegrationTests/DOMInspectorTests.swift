import Testing
import WebKit
@testable import WebInspectorRuntime

@MainActor
@Suite(.serialized)
struct DOMInspectorTests {
    @Test
    func inspectorStartsWithEmptyDocument() {
        let inspector = WIInspectorController().dom

        #expect(inspector.document.rootNode == nil)
        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func reloadDocumentWithoutPageThrowsPageUnavailable() async {
        let inspector = WIInspectorController().dom

        await #expect(throws: DOMOperationError.pageUnavailable) {
            try await inspector.reloadDocument()
        }
    }

}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

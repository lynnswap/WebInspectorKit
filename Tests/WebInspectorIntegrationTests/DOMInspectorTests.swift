import Testing
import WebKit
@testable import WebInspectorRuntime

@MainActor
@Suite(.serialized)
struct DOMInspectorTests {
    @Test
    func inspectorStartsWithEmptyDocument() {
        let runtime = WIDOMRuntime()

        #expect(runtime.document.rootNode == nil)
        #expect(runtime.document.selectedNode == nil)
        #expect(runtime.document.errorMessage == nil)
    }

    @Test
    func reloadDocumentWithoutPageThrowsPageUnavailable() async {
        let runtime = WIDOMRuntime()

        await #expect(throws: DOMOperationError.pageUnavailable) {
            try await runtime.reloadDocument()
        }
    }

}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

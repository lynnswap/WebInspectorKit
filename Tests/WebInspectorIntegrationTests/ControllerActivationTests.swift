import Testing
import WebKit
@_spi(Monocly) import WebInspectorRuntime
@testable import WebInspectorRuntime

@MainActor
@Suite(.serialized)
struct ControllerActivationTests {
    @Test
    func attachConnectsDOMRuntimeToPageWebView() async {
        let runtime = WIRuntimeSession()
        let webView = makeTestWebView()

        await runtime.attach(to: webView)

        #expect(runtime.dom.hasPageWebView == true)
    }

    @Test
    func detachDisconnectsDOMRuntimeFromPageWebView() async {
        let runtime = WIRuntimeSession()
        let webView = makeTestWebView()

        await runtime.attach(to: webView)
        #expect(runtime.dom.hasPageWebView == true)

        await runtime.detach()

        #expect(runtime.dom.hasPageWebView == false)
    }

    @Test
    func suspendPageAttachmentKeepsDOMPresentationWebView() async {
        let runtime = WIRuntimeSession()
        let webView = makeTestWebView()
        let presentationWebView = runtime.dom.treeWebViewForPresentation()

        await runtime.attach(to: webView)
        #expect(runtime.dom.hasPageWebView == true)

        await runtime.suspendPageAttachment()

        #expect(runtime.dom.hasPageWebView == false)
        #expect(runtime.dom.treeWebViewForPresentation() === presentationWebView)
    }

    @Test
    func detachDropsDOMPresentationWebView() async {
        let runtime = WIRuntimeSession()
        let webView = makeTestWebView()
        let presentationWebView = runtime.dom.treeWebViewForPresentation()

        await runtime.attach(to: webView)
        #expect(runtime.dom.hasPageWebView == true)

        await runtime.detach()

        #expect(runtime.dom.hasPageWebView == false)
        #expect(runtime.dom.treeWebViewForPresentation() !== presentationWebView)
    }
}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

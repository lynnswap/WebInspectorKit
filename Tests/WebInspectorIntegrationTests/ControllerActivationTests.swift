import Testing
import WebKit
@testable import WebInspectorRuntime

@MainActor
@Suite(.serialized)
struct ControllerActivationTests {
    @Test
    func connectWithDOMTabAttachesDOMOwner() async {
        let controller = WIInspectorController()
        controller.setTabs([.dom(), .network()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)

        #expect(controller.lifecycle == .active)
        #expect(controller.dom.hasPageWebView == true)
    }

    @Test
    func customTabWithoutDOMDoesNotAttachDOMOwner() async {
        let controller = WIInspectorController()
        controller.setTabs([
            WITab(
                id: "custom",
                title: "Custom",
                systemImage: "star"
            )
        ])

        await controller.connect(to: makeTestWebView())

        #expect(controller.dom.hasPageWebView == false)
    }

    @Test
    func suspendDetachesDOMOwner() async {
        let controller = WIInspectorController()
        controller.setTabs([.dom()])
        let webView = makeTestWebView()

        await controller.connect(to: webView)
        #expect(controller.dom.hasPageWebView == true)

        await controller.suspend()

        #expect(controller.lifecycle == .suspended)
        #expect(controller.dom.hasPageWebView == false)
    }
}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

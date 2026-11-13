#if canImport(UIKit)
import Testing
import WebKit
import WebInspectorKit
import WebKitTestWorkarounds

@MainActor
@Test
func publicUIKitModuleSupportsAttachAndDetachForConsumers() async throws {
    if #available(iOS 26.1, *) {
        try ScreenTimeWorkaround.install()
    }
    let inspector = WebInspector()
    let controller = WebInspectorViewController(inspector: inspector)

    let attach: @MainActor (WKWebView) -> Void = { webView in
        controller.inspector.attach(to: webView)
    }
    let detach: @MainActor () -> Void = {
        inspector.detach()
    }

    _ = attach
    _ = detach
    #expect(controller.inspector === inspector)
    #expect(inspector.state == .detached)
    _ = WebInspectorViewController()
}
#endif

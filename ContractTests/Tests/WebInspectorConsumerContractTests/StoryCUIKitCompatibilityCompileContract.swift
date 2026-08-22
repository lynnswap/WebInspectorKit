#if canImport(UIKit)
import Testing
import WebKit
import WebInspectorKit

@MainActor
@Test
func dropInUIKitFacadeAttachShapeCompilesForConsumers() {
    let session = WebInspectorSession()
    let inspector = WebInspectorViewController(session: session)

    let sessionAttach: @MainActor @Sendable (WKWebView) async throws -> Void = { webView in
        try await session.attach(to: webView)
    }
    let inspectorAttach: @MainActor @Sendable (WKWebView) async throws -> Void = { webView in
        try await inspector.attach(to: webView)
    }

    _ = sessionAttach
    _ = inspectorAttach
    _ = WebInspectorViewController()
}
#endif

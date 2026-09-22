#if canImport(UIKit)
import Testing
import WebKit
import WebInspectorKit

@MainActor
@Test
func publicUIKitModuleSupportsAttachAndDetachForConsumers() {
    let session = WebInspectorKit.WebInspectorSession()
    let inspector = WebInspectorKit.WebInspectorViewController(session: session)

    let sessionAttach: @MainActor @Sendable (WKWebView) async throws -> Void = { webView in
        try await session.attach(to: webView)
    }
    let inspectorAttach: @MainActor @Sendable (WKWebView) async throws -> Void = { webView in
        try await inspector.attach(to: webView)
    }

    let sessionDetach: @MainActor @Sendable () async -> Void = {
        await session.detach()
    }

    _ = sessionDetach
    _ = sessionAttach
    _ = inspectorAttach
    _ = WebInspectorViewController()
}
#endif

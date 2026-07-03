#if canImport(UIKit)
import Testing
import WebKit
import WebInspectorKit

@MainActor
@Test
func dropInUIKitFacadeAttachShapeCompilesForConsumers() {
    let session = WebInspectorSession()
    let inspector = WebInspectorViewController(session: session)

    let sessionAttach: @MainActor (WKWebView) async throws -> Void = session.attach(to:)
    let inspectorAttach: @MainActor (WKWebView) async throws -> Void = inspector.attach(to:)

    _ = sessionAttach
    _ = inspectorAttach
    _ = WebInspectorViewController()
}
#endif

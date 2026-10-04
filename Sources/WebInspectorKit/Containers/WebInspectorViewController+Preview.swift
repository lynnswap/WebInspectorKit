#if canImport(UIKit)
import SwiftUI
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM
import WebInspectorUINetwork

@MainActor
enum WebInspectorViewControllerPreviewFixtures {
    static func makeSession() -> WebInspectorSession {
        let dataContext = DOMPreviewFixtures.makeWebInspectorContext()
        NetworkPreviewFixtures.applySampleData(to: dataContext, mode: .detail)
        return WebInspectorSession(context: dataContext)
    }
}

private struct InspectorPreviewPreparation: PreviewModifier {
    static func makeSharedContext() async throws {
        try await WebInspectorSession.prepare()
    }

    func body(content: Content, context: Void) -> some View {
        content
    }
}

#Preview("WebInspectorViewController", traits: .modifier(InspectorPreviewPreparation())) {
    WebInspectorViewController(session: WebInspectorViewControllerPreviewFixtures.makeSession())
}
#endif

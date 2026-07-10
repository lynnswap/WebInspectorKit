#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM
import WebInspectorUINetwork

@MainActor
enum WebInspectorViewControllerPreviewFixtures {
    static func makeSession() -> WebInspectorSession {
        let dataContext = DOMPreviewFixtures.makeWebInspectorModelContext()
        NetworkPreviewFixtures.applySampleData(to: dataContext, mode: .detail)
        return WebInspectorSession(context: dataContext)
    }
}

#Preview("WebInspectorViewController") {
    WebInspectorViewController(session: WebInspectorViewControllerPreviewFixtures.makeSession())
}
#endif

#if canImport(UIKit)
import WebInspectorCore
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM
import WebInspectorUINetwork

@MainActor
enum WebInspectorViewControllerPreviewFixtures {
    static func makeSession() -> WebInspectorSession {
        let dataContext = DOMPreviewFixtures.makeWebInspectorContext()
        NetworkPreviewFixtures.applySampleData(to: dataContext, mode: .detail)
        return WebInspectorSession(
            inspector: InspectorSession(),
            dataContext: dataContext
        )
    }
}

#Preview("WebInspectorViewController") {
    WebInspectorViewController(session: WebInspectorViewControllerPreviewFixtures.makeSession())
}
#endif

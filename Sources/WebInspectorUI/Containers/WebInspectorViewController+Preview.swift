#if canImport(UIKit)
import WebInspectorCore
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM
import WebInspectorUINetwork

@MainActor
enum WebInspectorViewControllerPreviewFixtures {
    static func makeSession() -> WebInspectorSession {
        let session = WebInspectorSession(
            inspector: InspectorSession(
                attachment: AttachedInspection(
                    dom: DOMPreviewFixtures.makeDOMSession()
                )
            ),
            dataContext: NetworkPreviewFixtures.makeContext(mode: .detail)
        )
        return session
    }
}

#Preview("WebInspectorViewController") {
    WebInspectorViewController(session: WebInspectorViewControllerPreviewFixtures.makeSession())
}
#endif

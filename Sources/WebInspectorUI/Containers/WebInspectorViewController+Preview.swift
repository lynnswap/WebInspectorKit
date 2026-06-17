#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
enum WebInspectorViewControllerPreviewFixtures {
    static func makeSession() -> WebInspectorSession {
        let session = WebInspectorSession(
            inspector: InspectorSession(
                attachment: AttachedInspection(
                    dom: DOMPreviewFixtures.makeDOMSession(),
                    network: NetworkPreviewFixtures.makeNetworkSession(mode: .detail)
                )
            )
        )
        session.interface.networkPanelModel(for: session.attachment).refreshDisplayRowsSynchronously()
        return session
    }
}

#Preview("WebInspectorViewController") {
    WebInspectorViewController(session: WebInspectorViewControllerPreviewFixtures.makeSession())
}
#endif

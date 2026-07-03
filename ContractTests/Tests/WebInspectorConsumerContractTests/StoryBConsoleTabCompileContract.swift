#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorKit

@MainActor
@Test
func customUIKitTabFactoryReceivesWebInspectorSession() {
    let consoleTab = WebInspectorTab(
        id: "contract_console",
        title: "Console",
        systemImage: "terminal"
    ) { session in
        ContractConsoleViewController(inspectorSession: session)
    }

    let session = WebInspectorSession(tabs: [.dom, .network, consoleTab])
    let inspector = WebInspectorViewController(session: session)
    let inspectorWithTabs = WebInspectorViewController(tabs: [.dom, .network, consoleTab])

    #expect(inspector.session === session)
    #expect(inspector.automaticallyDetachesOnDismiss)
    inspector.automaticallyDetachesOnDismiss = false
    #expect(inspector.automaticallyDetachesOnDismiss == false)
    #expect(inspectorWithTabs.session.pageUserInterfaceStyle == .unspecified)
}

@MainActor
private final class ContractConsoleViewController: UIViewController {
    let inspectorSession: WebInspectorSession

    init(inspectorSession: WebInspectorSession) {
        self.inspectorSession = inspectorSession
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
#endif

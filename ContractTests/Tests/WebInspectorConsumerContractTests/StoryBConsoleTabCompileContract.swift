#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorKit
import WebKitTestWorkarounds

@MainActor
@Test
func customUIKitTabFactoryReceivesTheInspector() async throws {
    if #available(iOS 26.1, *) {
        try ScreenTimeWorkaround.install()
    }
    let consoleTab = WebInspectorTab(
        id: "contract_console",
        title: "Console",
        systemImage: "terminal"
    ) { inspector in
        ContractConsoleViewController(inspector: inspector)
    }

    let inspector = WebInspector()
    let controller = WebInspectorViewController(
        inspector: inspector,
        tabs: [.dom, .network, consoleTab]
    )

    #expect(controller.inspector === inspector)
    #expect(controller.automaticallyDetachesOnDismiss)
    controller.automaticallyDetachesOnDismiss = false
    #expect(controller.automaticallyDetachesOnDismiss == false)
    #expect(inspector.pageUserInterfaceStyle == .unspecified)
}

@MainActor
private final class ContractConsoleViewController: UIViewController {
    let inspector: WebInspector

    init(inspector: WebInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var messageCount: Int {
        inspector.console.messages.count
    }
}
#endif

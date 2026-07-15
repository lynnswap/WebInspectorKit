#if canImport(UIKit)
    import Testing
    import UIKit
    import WebInspectorDataKit
    import WebInspectorKit

    @MainActor
    @Test
    func customUIKitTabUsesCatalogContextAndBorrowedSessionInitializer() throws {
        let tabID = WebInspectorTab.ID(rawValue: "contract_console")
        let consoleTab = WebInspectorTab(
            id: tabID,
            title: "Console",
            systemImage: "terminal",
            requiredFeatures: [.consoleRuntime]
        ) { context in
            ContractConsoleViewController(context: context)
        }
        let catalog = try WebInspectorTabCatalog([.dom, .network, consoleTab])
        let session = WebInspectorSession()
        let inspector = WebInspectorViewController(
            session: session,
            catalog: catalog
        )

        #expect(inspector.session === session)
        #expect(session.modelContext === session.modelContainer.mainContext)
        #expect(consoleTab.id == tabID)
        #expect(consoleTab.requiredFeatures == [.consoleRuntime])
        #expect(throws: WebInspectorTabCatalogError.empty) {
            try WebInspectorTabCatalog([])
        }
        #expect(throws: WebInspectorTabCatalogError.duplicateID(tabID)) {
            try WebInspectorTabCatalog([consoleTab, consoleTab])
        }
    }

    @MainActor
    private final class ContractConsoleViewController: UIViewController {
        let session: WebInspectorSession
        let modelContainer: WebInspectorModelContainer
        let modelContext: WebInspectorModelContext

        init(context: WebInspectorTab.Context) {
            session = context.session
            modelContainer = context.modelContainer
            modelContext = context.modelContext
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }
    }
#endif

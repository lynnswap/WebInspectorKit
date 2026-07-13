import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
@testable import WebInspectorUIDOM

@MainActor
@Suite
struct DOMPanelModelTests {
    @Test
    func selectionUsesStableContextIdentityAndPreservesRevealIntent() async throws {
        let runtime = try await makeRuntime()
        let model = try await DOMPanelModel.make(context: runtime.model)
        let buttonID = try #require(model.nodes.snapshot.itemIDs.first { id in
            runtime.model.model(for: id)?.localName == "button"
        })
        let button = try #require(runtime.model.model(for: buttonID))

        model.selectNode(buttonID, reveal: .selectOnly)
        let firstRevision = model.selectionRevision

        #expect(model.selectedNode === button)
        #expect(model.selection?.nodeID == buttonID)
        #expect(model.selection?.revealPolicy == .selectOnly)
        #expect(model.selection?.revision == firstRevision)

        model.selectNode(buttonID, reveal: .selectAndScroll)

        #expect(model.selectedNode === button)
        #expect(model.selectionRevision == firstRevision + 1)
        #expect(model.selection?.revealPolicy == .selectAndScroll)
        await model.retire()
        await runtime.close()
    }

    @Test
    func replacingTheDocumentClearsSelectionThatLeftFetchedMembership() async throws {
        let runtime = try await makeRuntime()
        let model = try await DOMPanelModel.make(context: runtime.model)
        let buttonID = try #require(model.nodes.snapshot.itemIDs.first { id in
            runtime.model.model(for: id)?.localName == "button"
        })
        model.selectNode(buttonID, reveal: .selectAndScroll)

        try await runtime.replacePage(
            with: .init(children: [
                .element(id: "replacement", name: "main")
            ]),
            isolation: MainActor.shared
        )
        for _ in 0..<100 where model.selectedNodeID != nil {
            await Task.yield()
        }

        #expect(model.selectedNodeID == nil)
        #expect(model.selection == nil)
        await model.retire()
        await runtime.close()
    }

    @Test
    func retireClosesTheNodeFetchedResultsController() async throws {
        let runtime = try await makeRuntime()
        let model = try await DOMPanelModel.make(context: runtime.model)
        #expect(runtime.model.fetchedResultsControllerOwnerCountForTesting == 1)

        await model.retire()

        #expect(model.isRetiredForTesting)
        #expect(runtime.model.fetchedResultsControllerOwnerCountForTesting == 0)
        await runtime.close()
    }

    @Test
    func deinitBackstopRemovesTheNodeFetchedResultsOwner() async throws {
        let runtime = try await makeRuntime()
        var model: DOMPanelModel? = try await DOMPanelModel.make(
            context: runtime.model
        )
        #expect(runtime.model.fetchedResultsControllerOwnerCountForTesting == 1)

        model = nil

        #expect(model == nil)
        #expect(runtime.model.fetchedResultsControllerOwnerCountForTesting == 0)
        await runtime.close()
    }

    private func makeRuntime() async throws -> WebInspectorDataKitTestRuntime {
        try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(domains: [.dom]),
                document: .init(children: [
                    .element(id: "button", name: "button")
                ])
            ),
            isolation: MainActor.shared
        )
    }
}

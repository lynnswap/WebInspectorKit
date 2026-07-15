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
        let context = runtime.container.mainContext
        let model = try await DOMPanelModel.make(context: context)
        let buttonID = try #require(model.nodes.snapshot?.itemIDs.first { id in
            context.model(for: id)?.localName == "button"
        })
        let button = try #require(context.model(for: buttonID))

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
        let context = runtime.container.mainContext
        let model = try await DOMPanelModel.make(context: context)
        let buttonID = try #require(model.nodes.snapshot?.itemIDs.first { id in
            context.model(for: id)?.localName == "button"
        })
        model.selectNode(buttonID, reveal: .selectAndScroll)
        var updates = model.nodes.updates.makeAsyncIterator()
        _ = await updates.next()

        try await runtime.replacePage(
            with: .init(children: [
                .element(id: "replacement", name: "main")
            ])
        )
        _ = await updates.next()
        for _ in 0..<100 where model.selection != nil {
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
        let model = try await DOMPanelModel.make(
            context: runtime.container.mainContext
        )

        await model.retire()

        #expect(model.isRetiredForTesting)
        #expect(model.nodes.fetchError as? WebInspectorFetchError == .contextClosed)
        await runtime.close()
    }

    @Test
    func deinitBackstopClosesTheNodeFetchedResultsController() async throws {
        let runtime = try await makeRuntime()
        var model: DOMPanelModel? = try await DOMPanelModel.make(
            context: runtime.container.mainContext
        )
        let nodes = try #require(model?.nodes)

        model = nil

        #expect(model == nil)
        #expect(nodes.fetchError as? WebInspectorFetchError == .contextClosed)
        await runtime.close()
    }

    private func makeRuntime() async throws -> WebInspectorDataKitTestRuntime {
        try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.dom]),
                document: .init(children: [
                    .element(id: "button", name: "button")
                ])
            )
        )
    }
}

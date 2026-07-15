import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit
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
    func pickerSelectionWaitsForFetchedMembershipBeforePublishing() async throws {
        let runtime = try await makeRuntime()
        let context = runtime.container.mainContext
        let model = try await DOMPanelModel.make(context: context)
        let bodyID = try #require(model.nodes.snapshot?.itemIDs.first { id in
            context.model(for: id)?.localName == "button"
        })
        let selectedID = nodeID(rawValue: "picker-selection", in: bodyID)
        let observation = withPortableContinuousObservation { _ in
            _ = model.selection
        }
        let selections = await observation.values {
            model.selection
        }
        defer {
            selections.cancel()
            observation.cancel()
        }

        model.receivePickerSelectionForTesting(selectedID)

        #expect(model.selection == nil)
        #expect(model.pendingPickerSelectionIDForTesting == selectedID)

        try await runtime.emitDOMChildNodeInserted(
            parentID: "button",
            node: .element(id: "picker-selection", name: "span")
        )

        #expect(await selections.waitUntil {
            $0?.nodeID == selectedID
                && $0?.revealPolicy == .selectAndScroll
        } != nil)
        #expect(model.selectedNodeID == selectedID)
        #expect(model.selectedNode?.localName == "span")
        #expect(model.pendingPickerSelectionIDForTesting == nil)
        await model.retire()
        await runtime.close()
    }

    @Test
    func explicitSelectionAndPickerLifecycleSupersedePendingPickerSelection()
        async throws
    {
        let runtime = try await makeRuntime()
        let context = runtime.container.mainContext
        let model = try await DOMPanelModel.make(context: context)
        let buttonID = try #require(model.nodes.snapshot?.itemIDs.first { id in
            context.model(for: id)?.localName == "button"
        })
        let pendingID = nodeID(rawValue: "pending", in: buttonID)

        model.receivePickerSelectionForTesting(pendingID)
        model.selectNode(buttonID, reveal: .selectOnly)

        #expect(model.pendingPickerSelectionIDForTesting == nil)
        #expect(model.selectedNodeID == buttonID)

        model.receivePickerSelectionForTesting(pendingID)
        model.cancelElementPicker()

        #expect(model.pendingPickerSelectionIDForTesting == nil)
        #expect(model.selectedNodeID == buttonID)

        model.receivePickerSelectionForTesting(pendingID)
        model.toggleElementPicker()

        #expect(model.pendingPickerSelectionIDForTesting == nil)

        model.receivePickerSelectionForTesting(pendingID)
        await model.retire()

        #expect(model.pendingPickerSelectionIDForTesting == nil)
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

    private func nodeID(
        rawValue: String,
        in existingNodeID: DOMNode.ID
    ) -> DOMNode.ID {
        DOMNode.ID(
            canonical: WebInspectorDOMNodeIdentityStorage(
                documentScope: existingNodeID.canonicalStorage.documentScope,
                rawNodeID: DOM.Node.ID(rawValue)
            )
        )
    }
}

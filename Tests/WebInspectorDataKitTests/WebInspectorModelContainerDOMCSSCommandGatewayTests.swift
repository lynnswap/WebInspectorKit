import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit

@MainActor
@Test
func DOMAndCSSCommandsRouteThroughTheDOMFeatureFacade() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    try await withDataKitTestRuntime { runtime in
        try await prepareDOMFeatureAttachment(runtime)
        try await container.attach(owning: runtime.proxy)

        let results = WebInspectorFetchedResultsController<DOMNode>(
            modelContext: container.mainContext
        )
        do {
            try await results.performFetch()
            let body = try #require(
                results.fetchedObjects?.first { $0.localName == "body" }
            )

            await runtime.wire.respond(to: "DOM.setAttributeValue")
            let mutation = try await container.dom.setAttribute(
                "data-state",
                value: "ready",
                on: body.id,
                undo: .disabled
            )
            #expect(mutation.requestedNodeIDs == [body.id])
            #expect(mutation.appliedNodeIDs == [body.id])
            #expect(mutation.failures.isEmpty)
            #expect(mutation.undo == nil)

            await runtime.wire.respond(to: "DOM.highlightNode")
            try await container.dom.highlight(body.id)
            await runtime.wire.respond(to: "DOM.hideHighlight")
            try await container.dom.hideHighlight()

            await runtime.wire.respond(
                to: "CSS.getMatchedStylesForNode",
                with: try rawCSSMatchedStylesResult(.init())
            )
            await runtime.wire.respond(
                to: "CSS.getInlineStylesForNode",
                with: try rawCSSInlineStylesResult(.init())
            )
            await runtime.wire.respond(
                to: "CSS.getComputedStyleForNode",
                with: try rawCSSComputedStyleResult([])
            )
            let stylesID = try await container.dom.loadStyles(for: body.id)
            let stylesIDs = try await container.mainContext.fetchIdentifiers(
                WebInspectorFetchDescriptor<CSSStyles>()
            )
            #expect(stylesIDs.contains(stylesID))
            let styles = try #require(
                container.mainContext.model(for: stylesID)
            )
            #expect(styles.nodeID == body.id)
            #expect(styles.phase == .loaded)

            let methods = runtime.wire.observations.commands.map(\.method)
            #expect(methods.contains("DOM.setAttributeValue"))
            #expect(methods.contains("DOM.highlightNode"))
            #expect(methods.contains("DOM.hideHighlight"))
            #expect(methods.contains("CSS.getMatchedStylesForNode"))
            #expect(methods.contains("CSS.getInlineStylesForNode"))
            #expect(methods.contains("CSS.getComputedStyleForNode"))

            await results.close()
            await closeDOMFeatureAttachment(container, runtime: runtime)
        } catch {
            await results.close()
            await closeDOMFeatureAttachment(container, runtime: runtime)
            throw error
        }
    }
}

@MainActor
@Test
func DOMMutationCapabilityMarksAndReplaysTheAcceptingAgentHistory() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    try await withDataKitTestRuntime { runtime in
        try await prepareDOMFeatureAttachment(runtime)
        try await container.attach(owning: runtime.proxy)

        let results = WebInspectorFetchedResultsController<DOMNode>(
            modelContext: container.mainContext
        )
        do {
            try await results.performFetch()
            let body = try #require(
                results.fetchedObjects?.first { $0.localName == "body" }
            )

            await runtime.wire.respond(to: "DOM.setAttributeValue")
            await runtime.wire.respond(to: "DOM.markUndoableState")
            let mutation = try await container.dom.setAttribute(
                "data-state",
                value: "ready",
                on: body.id
            )
            let history = try #require(mutation.undo)

            await runtime.wire.respond(to: "DOM.undo")
            try await history.undo()
            await runtime.wire.respond(to: "DOM.redo")
            try await history.redo()

            let commands = runtime.wire.observations.commands.filter {
                [
                    "DOM.setAttributeValue",
                    "DOM.markUndoableState",
                    "DOM.undo",
                    "DOM.redo",
                ].contains($0.method)
            }
            #expect(
                commands.map(\.method) == [
                    "DOM.setAttributeValue",
                    "DOM.markUndoableState",
                    "DOM.undo",
                    "DOM.redo",
                ])
            #expect(commands.allSatisfy { $0.destination == .target("page-main") })

            await results.close()
            await closeDOMFeatureAttachment(container, runtime: runtime)
        } catch {
            await results.close()
            await closeDOMFeatureAttachment(container, runtime: runtime)
            throw error
        }
    }
}

@MainActor
@Test
func replacedDOMIdentityIsRejectedAtTheFeatureFacade() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom]),
            document: .init(children: [
                .element(id: "old-node", name: "body")
            ])
        )
    )
    let results = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: runtime.container.mainContext
    )

    do {
        try await results.performFetch()
        let oldID = try #require(
            results.fetchedObjects?.first { $0.localName == "body" }?.id
        )
        var updates = results.updates.makeAsyncIterator()
        guard case .initial = await updates.next() else {
            Issue.record("Expected the accepted initial DOM result.")
            await results.close()
            await runtime.close()
            return
        }

        _ = try await runtime.replacePage(
            with: .init(children: [
                .element(id: "new-node", name: "main")
            ])
        )
        _ = try #require(await updates.next())

        await #expect(throws: WebInspectorCommandError.staleIdentifier) {
            try await runtime.container.dom.highlight(oldID)
        }

        await results.close()
        await runtime.close()
    } catch {
        await results.close()
        await runtime.close()
        throw error
    }
}

@MainActor
private func prepareDOMFeatureAttachment(
    _ runtime: DataKitTestRuntime
) async throws {
    await runtime.wire.respond(to: "Page.enable")
    await runtime.wire.respond(to: "Inspector.enable")
    await runtime.wire.respond(to: "Inspector.initialized")
    await runtime.wire.respond(to: "CSS.enable")
    await runtime.wire.respond(
        to: "DOM.getDocument",
        with: try domDocumentResult(
            DOM.Node(
                id: DOM.Node.ID("document"),
                nodeType: 9,
                nodeName: "#document",
                frameID: FrameID("main-frame"),
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: DOM.Node.ID("body"),
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body"
                    )
                ]
            )
        )
    )
}

@MainActor
private func closeDOMFeatureAttachment(
    _ container: WebInspectorModelContainer,
    runtime: DataKitTestRuntime
) async {
    await runtime.wire.respond(to: "CSS.disable")
    await runtime.wire.respond(to: "Inspector.disable")
    await runtime.wire.respond(to: "Page.disable")
    await container.close()
}

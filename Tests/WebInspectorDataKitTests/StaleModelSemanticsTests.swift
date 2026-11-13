import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

private let staleDOMNodeError = WebInspectorProxyError.disconnected(
    "DOMNode is not registered in this WebInspectorContext."
)
@MainActor
@Test
func retainedDOMNodeAfterContextReleaseKeepsSnapshotAndFailsWithoutTrapping() async throws {
    var context: WebInspectorContext? = WebInspectorContext.preview()
    context?.seedDOMDocument(
        DOM.Node(
            id: DOM.Node.ID("released-node"),
            nodeType: 1,
            nodeName: "ARTICLE",
            localName: "article",
            attributes: ["data-state": "retained"]
        ))
    let node = try #require(context?.rootNode)
    weak let releasedContext = context

    context = nil

    #expect(releasedContext == nil)
    #expect(node.nodeName == "ARTICLE")
    #expect(node.attributes["data-state"] == "retained")
    await node.requestChildren()
    await #expect(throws: staleDOMNodeError) {
        try await node.copyText(.selectorPath)
    }
    await #expect(throws: staleDOMNodeError) {
        try await node.delete()
    }
    await #expect(throws: staleDOMNodeError) {
        try await node.highlight()
    }
}

@MainActor
@Test
func staleAndForeignDOMNodesNeverRebindToSameIDReplacement() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = WebInspectorContext(container)
    let foreignContext = WebInspectorContext(container)
    let sharedID = DOM.Node.ID("same-node-id")
    context.seedDOMDocument(
        DOM.Node(
            id: sharedID,
            nodeType: 1,
            nodeName: "OLD",
            localName: "old"
        ))
    foreignContext.seedDOMDocument(
        DOM.Node(
            id: sharedID,
            nodeType: 1,
            nodeName: "FOREIGN",
            localName: "foreign",
            childNodeCount: 1,
            children: [
                DOM.Node(
                    id: DOM.Node.ID("foreign-distinct-id"),
                    nodeType: 1,
                    nodeName: "DISTINCT",
                    localName: "distinct"
                )
            ]
        ))
    let staleNode = try #require(context.rootNode)
    let foreignNode = try #require(foreignContext.rootNode)
    let foreignDistinctNode = try #require(
        foreignContext.node(for: DOMNode.ID(DOM.Node.ID("foreign-distinct-id")))
    )

    context.apply(DOM.Event.documentUpdated)
    context.seedDOMDocument(
        DOM.Node(
            id: sharedID,
            nodeType: 1,
            nodeName: "FRESH",
            localName: "fresh"
        ))
    let freshNode = try #require(context.rootNode)
    #expect(freshNode !== staleNode)
    #expect(freshNode.id == staleNode.id)
    context.select(freshNode)
    let selectionTree = context.dom.treeController()
    let selectionRevision = selectionTree.revision
    let selectedNodeID = selectionTree.snapshot.selectedNodeID
    let commandsBeforeStaleOperations = await runtime.backend.recordedCommands()

    await staleNode.requestChildren()
    context.select(staleNode)
    context.select(foreignNode)
    context.select(foreignDistinctNode)

    #expect(context.selectedNode === freshNode)
    #expect(selectionTree.revision == selectionRevision)
    #expect(selectionTree.snapshot.selectedNodeID == selectedNodeID)
    #expect(await runtime.backend.recordedCommands() == commandsBeforeStaleOperations)
    await #expect(throws: staleDOMNodeError) {
        try await staleNode.copyText(.selectorPath)
    }
    await #expect(throws: staleDOMNodeError) {
        try await staleNode.delete()
    }
    await #expect(throws: staleDOMNodeError) {
        try await staleNode.highlight()
    }
    #expect(throws: staleDOMNodeError) {
        try context.selectorPath(for: staleNode)
    }
    #expect(throws: staleDOMNodeError) {
        try context.xPath(for: foreignNode)
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.copyText(.selectorPath, for: foreignNode)
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.delete(foreignNode)
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.highlight(foreignNode)
    }

    let staleRootError = WebInspectorProxyError.disconnected(
        "DOMTreeController root is not registered in this WebInspectorContext."
    )
    #expect(context.domTreeRegistrationCountForTesting() == 1)
    await #expect(throws: staleRootError) {
        _ = try await context.treeController(root: staleNode)
    }
    await #expect(throws: staleRootError) {
        _ = try await context.treeController(root: foreignDistinctNode)
    }
    #expect(context.domTreeRegistrationCountForTesting() == 1)

    #expect(try context.selectorPath(for: freshNode) == "fresh")
    let currentTree = try await context.treeController(root: freshNode)
    #expect(currentTree.snapshot.rootNodeID == freshNode.id)
    #expect(context.domTreeRegistrationCountForTesting() == 2)
    context.select(nil)
    #expect(context.selectedNode == nil)
    #expect(await runtime.backend.recordedCommands() == commandsBeforeStaleOperations)
    #expect(context.state == .attaching)
}

@MainActor
@Test
func staleAndForeignRuntimeContextsPreserveTheCurrentSelection() async throws {
    let context = WebInspectorContext.preview()
    let foreignContext = WebInspectorContext.preview()
    let sharedID = Runtime.ExecutionContext.ID("same-runtime-id")
    context.apply(
        .executionContextCreated(
            Runtime.ExecutionContext(
                id: sharedID,
                name: "Old",
                kind: .normal
            )))
    let staleContext = try #require(context.executionContexts.first)
    context.apply(.executionContextDestroyed(sharedID))
    context.apply(
        .executionContextCreated(
            Runtime.ExecutionContext(
                id: sharedID,
                name: "Fresh",
                kind: .normal
            )))
    foreignContext.apply(
        .executionContextCreated(
            Runtime.ExecutionContext(
                id: sharedID,
                name: "Foreign",
                kind: .normal
            )))
    let freshContext = try #require(context.executionContexts.first)
    let foreignRuntimeContext = try #require(foreignContext.executionContexts.first)
    #expect(freshContext !== staleContext)
    #expect(freshContext.id == staleContext.id)

    context.selectContext(freshContext)
    context.selectContext(staleContext)
    context.selectContext(foreignRuntimeContext)

    #expect(context.selectedContext === freshContext)
    let error = WebInspectorProxyError.disconnected(
        "RuntimeContext is not registered in this WebInspectorContext."
    )
    await #expect(throws: error) {
        _ = try await context.evaluate("1", in: staleContext)
    }
    await #expect(throws: error) {
        _ = try await context.evaluate("1", in: foreignRuntimeContext)
    }
    #expect(context.selectedContext === freshContext)
    context.selectContext(nil)
    #expect(context.selectedContext == nil)
    #expect(context.state == .attached)
}

@MainActor
@Test
func contextReleaseFinishesCollectionChangeStreams() async throws {
    var container: WebInspectorContainer? = WebInspectorContainer(proxy: WebInspectorProxy())
    var context: WebInspectorContext? = WebInspectorContext(try #require(container))
    var requestChanges = try #require(context?.network.requestChanges).makeAsyncIterator()
    var messageChanges = try #require(context?.console.messageChanges).makeAsyncIterator()

    context = nil
    container = nil

    #expect(await requestChanges.next() == nil)
    #expect(await messageChanges.next() == nil)
}

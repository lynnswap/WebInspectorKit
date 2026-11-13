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
func retainedDOMNodeAfterContextReleaseKeepsItsLastState() async throws {
    var context: WebInspectorContext? = WebInspectorContext.preview()
    context?.seedDOMDocument(
        DOM.Node(
            id: DOM.Node.ID("released-node"),
            nodeType: 1,
            nodeName: "ARTICLE",
            localName: "article",
            attributes: ["data-state": "retained"]
        ))
    let node = try #require(context?.dom.rootNode)
    weak let releasedContext = context

    context = nil

    #expect(releasedContext == nil)
    #expect(node.nodeName == "ARTICLE")
    #expect(node.attributes["data-state"] == "retained")
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
    let staleNode = try #require(context.dom.rootNode)
    let foreignNode = try #require(foreignContext.dom.rootNode)
    let foreignDistinctNode = try #require(
        foreignContext.dom.node(for: DOMNode.ID(DOM.Node.ID("foreign-distinct-id")))
    )

    context.apply(DOM.Event.documentUpdated)
    context.seedDOMDocument(
        DOM.Node(
            id: sharedID,
            nodeType: 1,
            nodeName: "FRESH",
            localName: "fresh"
        ))
    let freshNode = try #require(context.dom.rootNode)
    #expect(freshNode !== staleNode)
    #expect(freshNode.id == staleNode.id)
    context.dom.select(freshNode)
    let selectionTree = context.dom.treeController()
    let selectionRevision = selectionTree.revision
    let selectedNodeID = selectionTree.snapshot.selectedNodeID
    let commandsBeforeStaleOperations = await runtime.backend.recordedCommands()

    await context.dom.requestChildren(of: staleNode)
    context.dom.select(staleNode)
    context.dom.select(foreignNode)
    context.dom.select(foreignDistinctNode)

    #expect(context.dom.selectedNode === freshNode)
    #expect(selectionTree.revision == selectionRevision)
    #expect(selectionTree.snapshot.selectedNodeID == selectedNodeID)
    #expect(await runtime.backend.recordedCommands() == commandsBeforeStaleOperations)
    await #expect(throws: staleDOMNodeError) {
        try await context.dom.copyText(.selectorPath, of: staleNode)
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.dom.remove([staleNode])
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.dom.highlight(staleNode)
    }
    #expect(throws: staleDOMNodeError) {
        try context.dom.selectorPath(for: staleNode)
    }
    #expect(throws: staleDOMNodeError) {
        try context.dom.xPath(for: foreignNode)
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.dom.copyText(.selectorPath, of: foreignNode)
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.dom.remove([foreignNode])
    }
    await #expect(throws: staleDOMNodeError) {
        try await context.dom.highlight(foreignNode)
    }

    #expect(try context.dom.selectorPath(for: freshNode) == "fresh")
    context.dom.select(nil)
    #expect(context.dom.selectedNode == nil)
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
    let staleContext = try #require(context.runtime.executionContexts.first)
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
    let freshContext = try #require(context.runtime.executionContexts.first)
    let foreignRuntimeContext = try #require(foreignContext.runtime.executionContexts.first)
    #expect(freshContext !== staleContext)
    #expect(freshContext.id == staleContext.id)

    context.runtime.select(freshContext)
    context.runtime.select(staleContext)
    context.runtime.select(foreignRuntimeContext)

    #expect(context.runtime.selectedContext === freshContext)
    let error = WebInspectorProxyError.disconnected(
        "RuntimeContext is not registered in this WebInspectorContext."
    )
    await #expect(throws: error) {
        _ = try await context.runtime.evaluate("1", in: staleContext)
    }
    await #expect(throws: error) {
        _ = try await context.runtime.evaluate("1", in: foreignRuntimeContext)
    }
    #expect(context.runtime.selectedContext === freshContext)
    context.runtime.select(nil)
    #expect(context.runtime.selectedContext == nil)
    #expect(context.state == .attached)
}

@MainActor
@Test
func foreignNetworkRequestKeepsItsResponseBodyFetchable() async throws {
    let context = WebInspectorContext.preview()
    let foreignContext = WebInspectorContext.preview()
    let requestID = Network.Request.ID("foreign-body")
    foreignContext.apply(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/body", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
    foreignContext.apply(
        .responseReceived(
            id: requestID,
            response: Network.Response(status: 200, mimeType: "text/plain"),
            resourceType: .fetch,
            timestamp: 2
        ))
    foreignContext.apply(.loadingFinished(id: requestID, timestamp: 3, sourceMapURL: nil, metrics: nil))
    let foreignRequest = try #require(foreignContext.network.requests.first)
    #expect(foreignRequest.canFetchResponseBody)

    await context.network.fetchResponseBody(for: foreignRequest)

    #expect(foreignRequest.responseBody.phase == .available)
    #expect(foreignRequest.canFetchResponseBody)
}

@MainActor
@Test
func retainedRuntimeObjectAfterContextReleaseHasNoRemoteHandle() async throws {
    var context: WebInspectorContext? = WebInspectorContext.preview()
    context?.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "retained",
            parameters: [
                Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("retained-object"),
                    kind: .object,
                    description: "retained object"
                )
            ]
        )))
    let object = try #require(context?.console.messages.first?.parameters.first)
    #expect(object.canRequestProperties)

    context = nil

    #expect(object.description == "retained object")
    #expect(object.canRequestProperties == false)
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

import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

private let staleDOMNodeError = WebInspectorProxyError.disconnected(
    "DOMNode is not registered in this WebInspectorContext."
)
private let staleFetchedResultsError = WebInspectorProxyError.disconnected(
    "WebInspectorFetchedResults is not registered in this WebInspectorContext."
)

@MainActor
@Test
func retainedDOMNodeAfterContextReleaseKeepsSnapshotAndFailsWithoutTrapping() async throws {
    var context: WebInspectorContext? = WebInspectorContext.preview(isolation: MainActor.shared)
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
    let context = WebInspectorContext(container, isolation: MainActor.shared)
    let foreignContext = WebInspectorContext(container, isolation: MainActor.shared)
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
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let foreignContext = WebInspectorContext.preview(isolation: MainActor.shared)
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
func contextReleaseFinishesEveryFetchedResultsStreamAndRetainsFinalSnapshots() async throws {
    var context: WebInspectorContext? = WebInspectorContext.preview(isolation: MainActor.shared)
    context?.seedNetworkRequest(
        requestID: "retained-request",
        url: "https://example.test/data.json",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 1
    )
    context?.apply(
        .messageAdded(
            Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "retained message"
            )))
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = try #require(context?.fetchedResults())
    let secondNetworkResults: WebInspectorFetchedResults<NetworkRequest> = try #require(context?.fetchedResults())
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = try #require(context?.fetchedResults())
    let networkController = WebInspectorFetchedResultsController(fetchedResults: networkResults)
    let consoleController = WebInspectorFetchedResultsController(fetchedResults: consoleResults)
    let retainedNetworkSnapshot = networkController.snapshot
    let retainedConsoleSnapshot = consoleController.snapshot
    var activeNetworkIterator = networkController.transactions.makeAsyncIterator()
    var secondActiveIterator = WebInspectorFetchedResultsController(
        fetchedResults: secondNetworkResults
    ).transactions.makeAsyncIterator()
    var activeConsoleIterator = consoleController.transactions.makeAsyncIterator()
    weak let releasedContext = context

    context = nil

    #expect(releasedContext == nil)
    #expect(await activeNetworkIterator.next() == nil)
    #expect(await secondActiveIterator.next() == nil)
    #expect(await activeConsoleIterator.next() == nil)
    var lateNetworkIterator = networkController.transactions.makeAsyncIterator()
    var lateConsoleIterator = consoleController.transactions.makeAsyncIterator()
    #expect(await lateNetworkIterator.next() == nil)
    #expect(await lateConsoleIterator.next() == nil)
    #expect(networkController.snapshot == retainedNetworkSnapshot)
    #expect(consoleController.snapshot == retainedConsoleSnapshot)
    #expect(networkResults.items.map(\.url) == ["https://example.test/data.json"])
    #expect(consoleResults.items.map(\.text) == ["retained message"])

    let networkDescriptor = WebInspectorFetchDescriptor<NetworkRequest>(fetchLimit: 1)
    #expect(throws: staleFetchedResultsError) {
        try networkResults.updateFetchDescriptor(networkDescriptor)
    }
    #expect(throws: staleFetchedResultsError) {
        try networkResults.updateFetchDescriptor(networkDescriptor)
    }
    #expect(throws: staleFetchedResultsError) {
        try networkController.updateFetchDescriptor(networkDescriptor)
    }
}

@MainActor
@Test
func liveFetchedResultsRemainRegisteredAcrossContextStatesAndRejectForeignUpdates() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let foreignContext = WebInspectorContext.preview(isolation: MainActor.shared)
    let networkResults: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
    let networkController = WebInspectorFetchedResultsController(fetchedResults: networkResults)
    let consoleController = WebInspectorFetchedResultsController(fetchedResults: consoleResults)
    let firstNetworkDescriptor = WebInspectorFetchDescriptor<NetworkRequest>(fetchLimit: 2)
    let firstConsoleDescriptor = WebInspectorFetchDescriptor<ConsoleMessage>(fetchLimit: 2)

    try networkResults.updateFetchDescriptor(firstNetworkDescriptor)
    try consoleController.updateFetchDescriptor(firstConsoleDescriptor)
    #expect(networkResults.fetchDescriptor.fetchLimit == 2)
    #expect(consoleResults.fetchDescriptor.fetchLimit == 2)

    await context.stop()
    #expect(context.state == .detached)
    try networkController.updateFetchDescriptor(WebInspectorFetchDescriptor(fetchLimit: 3))
    try consoleResults.updateFetchDescriptor(WebInspectorFetchDescriptor(fetchLimit: 3))
    #expect(networkResults.fetchDescriptor.fetchLimit == 3)
    #expect(consoleResults.fetchDescriptor.fetchLimit == 3)

    context.start()
    #expect(context.state == .attaching)
    try networkResults.updateFetchDescriptor(WebInspectorFetchDescriptor(fetchLimit: 4))
    try consoleController.updateFetchDescriptor(WebInspectorFetchDescriptor(fetchLimit: 4))
    #expect(networkResults.fetchDescriptor.fetchLimit == 4)
    #expect(consoleResults.fetchDescriptor.fetchLimit == 4)

    #expect(throws: staleFetchedResultsError) {
        try foreignContext.updateFetchDescriptor(
            WebInspectorFetchDescriptor<NetworkRequest>(fetchLimit: 1),
            for: networkResults
        )
    }
    #expect(networkResults.fetchDescriptor.fetchLimit == 4)
}

import Foundation
import Testing
import WebInspectorDataKit

@MainActor
@Test
func webInspectorDataKitBaseSurfaceDoesNotRequireProxyKitImport() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(
            enabledFeatures: [.dom, .network, .consoleRuntime]
        )
    )
    let consumer = try DataKitImportOnlyActor(modelContainer: container)

    #expect(consumer.modelContainer === container)

    await consumer.closeModelContext()
    await container.close()
}

@WebInspectorModelActor
private actor DataKitImportOnlyActor {
    func queryEmptyStore() async throws -> Bool {
        var requestDescriptor = WebInspectorFetchDescriptor<NetworkRequest>(
            predicate: #Predicate { $0.method == "GET" },
            sortBy: [SortDescriptor(\.insertionIndex)]
        )
        requestDescriptor.fetchOffset = 0
        requestDescriptor.fetchLimit = 10

        let requests = WebInspectorFetchedResultsController<NetworkRequest>(
            fetchDescriptor: requestDescriptor,
            modelContext: modelContext
        )
        let messages = WebInspectorFetchedResultsController<ConsoleMessage>(
            fetchDescriptor: .init(
                sortBy: [SortDescriptor(\.insertionIndex, order: .reverse)]
            ),
            modelContext: modelContext
        )
        let nodes = WebInspectorFetchedResultsController<DOMNode>(
            modelContext: modelContext
        )
        let runtimeContexts = WebInspectorFetchedResultsController<RuntimeContext>(
            modelContext: modelContext
        )

        try await requests.performFetch()
        try await messages.performFetch()
        try await nodes.performFetch()
        try await runtimeContexts.performFetch()

        let requestSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>? =
            requests.snapshot
        _ = requests.fetchDescriptor
        _ = requests.revision
        _ = requests.fetchError
        _ = requests.updates
        _ = requestSnapshot?.itemIDs.first.flatMap(modelContext.model(for:))

        try await requests.refetch(
            using: WebInspectorFetchDescriptor<NetworkRequest>(
                sortBy: [SortDescriptor(\.insertionIndex, order: .reverse)]
            )
        )

        let isEmpty =
            requests.fetchedObjects?.isEmpty == true
            && messages.fetchedObjects?.isEmpty == true
            && nodes.fetchedObjects?.isEmpty == true
            && runtimeContexts.fetchedObjects?.isEmpty == true

        await runtimeContexts.close()
        await nodes.close()
        await messages.close()
        await requests.close()
        return isEmpty
    }

    func featureFacadeSurface(
        nodeID: DOMNode.ID,
        stylesID: CSSStyles.ID,
        propertyID: CSSStyleProperty.ID,
        requestID: NetworkRequest.ID,
        runtimeContextID: RuntimeContext.ID,
        object: RuntimeObject
    ) async throws {
        _ = modelContainer.dom.state
        _ = modelContainer.dom.stateUpdates
        _ = modelContainer.dom.elementPickerState
        _ = modelContainer.dom.elementPickerStateUpdates
        await modelContainer.dom.retry()
        _ = try await modelContainer.dom.requestChildren(of: nodeID, depth: 1)
        _ = try await modelContainer.dom.setAttribute(
            "data-contract",
            value: "ready",
            on: nodeID
        )
        _ = try await modelContainer.dom.setOuterHTML(
            "<main></main>",
            of: nodeID
        )
        _ = try await modelContainer.dom.removeNodes([nodeID])
        _ = try await modelContainer.dom.text(.selectorPath, for: nodeID)
        try await modelContainer.dom.highlight(nodeID)
        try await modelContainer.dom.hideHighlight()
        _ = try await modelContainer.dom.loadStyles(for: nodeID)
        try await modelContainer.dom.refreshStyles(stylesID)
        _ = try await modelContainer.dom.setProperty(propertyID, enabled: true)
        _ = try await modelContainer.dom.setDeclarationText(
            "color: red;",
            for: propertyID
        )

        _ = modelContainer.network.state
        _ = modelContainer.network.stateUpdates
        try await modelContainer.network.clear()
        _ = try await modelContainer.network.responseBody(for: requestID)

        _ = modelContainer.console.state
        _ = modelContainer.console.stateUpdates
        await modelContainer.console.retry()
        try await modelContainer.console.clear()

        _ = modelContainer.runtime.state
        _ = modelContainer.runtime.stateUpdates
        await modelContainer.runtime.retry()
        let scope = await modelContainer.runtime.makeObjectScope()
        _ = try await scope.evaluate("1 + 1", in: runtimeContextID)
        _ = try await scope.properties(of: object)
        _ = try await scope.preview(of: object)
        _ = try await scope.entries(of: object)
        await scope.close()

        try await modelContainer.page.reload(ignoringCache: true)
    }

    func inspectMaterializedModels(
        nodeID: DOMNode.ID,
        requestID: NetworkRequest.ID,
        messageID: ConsoleMessage.ID
    ) {
        if let node = modelContext.model(for: nodeID) {
            _ = node.nodeName
            _ = node.localName
            _ = node.attributes
            _ = node.attributeList.first?.name
            _ = node.children
        }
        if let request = modelContext.model(for: requestID) {
            _ = request.url
            _ = request.state
            _ = request.hasResponse
            _ = request.hasResponseBody
            _ = request.metrics
        }
        if let message = modelContext.model(for: messageID) {
            _ = message.text
            _ = message.parameters.first?.description
        }
    }
}

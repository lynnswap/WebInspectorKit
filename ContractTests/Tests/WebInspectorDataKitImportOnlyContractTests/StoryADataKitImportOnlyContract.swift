import Testing
import WebInspectorDataKit

@Test
func webInspectorDataKitBaseSurfaceDoesNotRequireProxyKitImport() {
    _ = DataKitImportOnlyActor()
}

private actor DataKitImportOnlyActor {
    func consume(_ context: WebInspectorContext) async throws {
        let requests: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults()
        let messages: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults()
        let requestsByMethod: WebInspectorFetchedResults<NetworkRequest> =
            context.fetchedResults(sectionBy: \.method)
        let messagesByLevel: WebInspectorFetchedResults<ConsoleMessage> =
            context.fetchedResults(sectionBy: \.level)
        let requestController: WebInspectorFetchedResultsController<NetworkRequest> =
            context.fetchedResultsController()
        let messageController: WebInspectorFetchedResultsController<ConsoleMessage> =
            context.fetchedResultsController()

        _ = context.state
        _ = context.rootNode?.children
        _ = context.selectedNode?.attributes
        _ = context.selectedNode?.attributeList.first?.name
        context.clearNetworkRequests()
        let treeController = try await context.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        _ = treeSnapshot.rootNodeID
        _ = treeSnapshot.nodesByID.values.first?.attributeList.first?.value
        _ = treeController.transactions
        _ = requests.items.first?.url
        _ = requests.items.first?.state
        _ = requests.items.first?.hasResponse
        _ = requests.items.first?.hasResponseBody
        _ = requests.items.first?.metrics
        _ = requestsByMethod.sections.first?.title
        let requestSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> =
            requestController.snapshot
        let requestTransaction = WebInspectorFetchedResultsTransaction<NetworkRequest>(
            oldSnapshot: requestSnapshot,
            newSnapshot: requestSnapshot,
            itemChanges: []
        )
        _ = requestController.transactions
        _ = requestTransaction.hasChanges
        _ = messages.items.first?.text
        _ = messages.items.first?.parameters.first?.description
        _ = messagesByLevel.sections.first?.id
        _ = messageController.snapshot
        _ = messageController.transactions
        _ = try await context.evaluate("1 + 1").object.description

        let request = NetworkRequestSnapshot(url: "https://example.com", method: "GET")
        let response = NetworkResponseSnapshot(status: 200, mimeType: "text/html")
        let redirect = RedirectHop(request: request, response: response, timestamp: 1)
        _ = redirect.request.url
        _ = redirect.response.status
    }
}

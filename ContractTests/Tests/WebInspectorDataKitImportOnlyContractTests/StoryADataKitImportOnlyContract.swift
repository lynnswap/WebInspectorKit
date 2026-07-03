import Testing
import WebInspectorDataKit

@Test
func webInspectorDataKitBaseSurfaceDoesNotRequireProxyKitImport() {
    _ = DataKitImportOnlyActor()
}

private actor DataKitImportOnlyActor {
    func consume(_ context: WebInspectorContext) async throws {
        let requests: WebInspectorFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
        let messages: WebInspectorFetchedResults<ConsoleMessage> = context.fetchedResults(for: .allConsoleMessages)

        _ = context.state
        _ = context.rootNode?.children
        _ = context.selectedNode?.attributes
        let treeController = try await context.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        _ = treeSnapshot.rootNodeID
        _ = treeController.transactions
        _ = requests.items.first?.url
        _ = requests.items.first?.state
        _ = requests.items.first?.metrics
        _ = messages.items.first?.text
        _ = messages.items.first?.parameters.first?.description
        _ = try await context.evaluate("1 + 1").object.description

        let request = NetworkRequestSnapshot(url: "https://example.com", method: "GET")
        let response = NetworkResponseSnapshot(status: 200, mimeType: "text/html")
        let redirect = RedirectHop(request: request, response: response, timestamp: 1)
        _ = redirect.request.url
        _ = redirect.response.status
    }
}

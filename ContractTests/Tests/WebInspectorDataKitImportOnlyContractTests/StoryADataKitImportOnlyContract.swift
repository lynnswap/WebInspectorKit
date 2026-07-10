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
        _ = context.state
        _ = context.rootNode?.children
        _ = context.selectedNode?.attributes
        _ = context.selectedNode?.attributeList.first?.name
        _ = context.selectedNode?.elementStyles?.sections.first?.rule?.selectorText
        _ = context.selectedNode?.elementStyles?.sections.first?.style.properties.first?.name
        _ = context.selectedNode?.elementStyles?.computedProperties.first?.value
        _ = context.isElementPickerEnabled
        context.clearNetworkRequests()
        let treeController = try await context.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        _ = treeSnapshot.rootNodeID
        _ = treeSnapshot.nodesByID.values.first?.attributeList.first?.value
        _ = treeSnapshot.rootNodeID.map { treeSnapshot.selectorPath(for: $0) }
        _ = treeSnapshot.rootNodeID.map { treeSnapshot.xPath(for: $0) }
        _ = treeController.revision
        _ = treeController.selectedNodeID
        _ = treeController.updates
        _ = treeController.revealRequests
        if let selectedNode = context.selectedNode {
            _ = try context.selectorPath(for: selectedNode)
            _ = try context.xPath(for: selectedNode)
            _ = try await selectedNode.copyText(.selectorPath)
            try await selectedNode.highlight()
            try await selectedNode.delete()
        }
        try await context.hideHighlight()
        try await context.setElementPickerEnabled(false)
        try await context.reloadPage()
        _ = requests.items.first?.url
        _ = requests.items.first?.state
        _ = requests.items.first?.hasResponse
        _ = requests.items.first?.hasResponseBody
        _ = requests.items.first?.metrics
        _ = requestsByMethod.sections.first?.title
        let requestSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> =
            requests.snapshot
        let requestTransaction = WebInspectorFetchedResultsTransaction<NetworkRequest.ID>(
            oldSnapshot: requestSnapshot,
            newSnapshot: requestSnapshot,
            itemChanges: []
        )
        _ = requests.revision
        _ = requests.updates()
        _ = requestTransaction.hasChanges
        _ = messages.items.first?.text
        _ = messages.items.first?.parameters.first?.description
        _ = messagesByLevel.sections.first?.id
        _ = messages.snapshot
        _ = messages.revision
        _ = messages.updates()
        _ = try await context.evaluate("1 + 1").object.description

        let request = NetworkRequestSnapshot(url: "https://example.com", method: "GET")
        let response = NetworkResponseSnapshot(status: 200, mimeType: "text/html")
        let redirect = RedirectHop(request: request, response: response, timestamp: 1)
        _ = redirect.request.url
        _ = redirect.response.status
    }
}

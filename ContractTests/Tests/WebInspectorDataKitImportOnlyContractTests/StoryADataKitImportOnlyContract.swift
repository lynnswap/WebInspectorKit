import Testing
import WebInspectorDataKit

@MainActor
@Test
func webInspectorDataKitBaseSurfaceDoesNotRequireProxyKitImport() {
    _ = DataKitImportOnlyConsumer()
}

@Test
func dataKitLegacyNetworkResponseSnapshotInitializerFunctionReferenceRemainsUsable() {
    let makeResponseSnapshot = NetworkResponseSnapshot.init
    let response = makeResponseSnapshot(nil, 204, nil, nil, [:], nil, nil)

    #expect(response.status == 204)
    #expect(response.security == nil)
}

@MainActor
private final class DataKitImportOnlyConsumer {
    func consume(_ context: WebInspector) async throws {
        let requests = context.network.requests
        let messages = context.console.messages
        let requestChanges: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> =
            context.network.requestChanges
        let messageChanges: AsyncStream<WebInspectorCollectionChange<ConsoleMessage>> =
            context.console.messageChanges
        _ = requestChanges
        _ = messageChanges
        _ = WebInspectorCollectionChange<NetworkRequest>.removedAll
        _ = WebInspectorCollectionChange<NetworkRequest>.inserted([])
        _ = WebInspectorCollectionChange<NetworkRequest>.updated([])

        _ = context.state
        _ = context.dom.rootNode?.children
        _ = context.dom.selectedNode?.attributes
        _ = context.dom.selectedNode?.attributeList.first?.name
        _ = context.dom.selectedNode?.elementStyles?.sections.first?.rule?.selectorText
        _ = context.dom.selectedNode?.elementStyles?.sections.first?.style.properties.first?.name
        _ = context.dom.selectedNode?.elementStyles?.computedProperties.first?.value
        _ = context.dom.isElementPickerEnabled
        context.network.clearRequests()
        let treeController = context.dom.treeController()
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        _ = treeSnapshot.rootNodeID
        _ = treeSnapshot.nodesByID.values.first?.attributeList.first?.value
        _ = treeSnapshot.rootNodeID.map { treeSnapshot.selectorPath(for: $0) }
        _ = treeSnapshot.rootNodeID.map { treeSnapshot.xPath(for: $0) }
        _ = treeController.revision
        _ = treeController.selectedNodeID
        _ = treeController.updates
        _ = treeController.revealRequests
        if let selectedNode = context.dom.selectedNode {
            _ = try context.dom.selectorPath(for: selectedNode)
            _ = try context.dom.xPath(for: selectedNode)
            _ = try await context.dom.copyText(.selectorPath, of: selectedNode)
            try await context.dom.highlight(selectedNode)
            try await context.dom.remove([selectedNode])
        }
        try await context.dom.hideHighlight()
        try await context.dom.setElementPickerEnabled(false)
        try await context.page.reload()
        _ = requests.first?.url
        _ = requests.first?.state
        _ = requests.first?.hasResponse
        _ = requests.first?.hasResponseBody
        _ = requests.first?.metrics
        _ = requests.first?.security?.connection?.tlsProtocol
        _ = requests.first?.security?.certificate?.dnsNames
        _ = messages.first?.text
        _ = messages.first?.parameters.first?.description
        _ = try await context.runtime.evaluate("1 + 1").object.description

        let request = NetworkRequestSnapshot(url: "https://example.com", method: "GET")
        let response = NetworkResponseSnapshot(status: 200, mimeType: "text/html")
        if let security = requests.first?.security {
            _ = response.reporting(security: security)
        }
        let redirect = RedirectHop(request: request, response: response, timestamp: 1)
        _ = redirect.request.url
        _ = redirect.response.status
        _ = redirect.response.security?.certificate?.subject
    }
}

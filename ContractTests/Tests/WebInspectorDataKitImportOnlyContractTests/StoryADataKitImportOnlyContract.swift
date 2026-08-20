import Testing
import WebInspectorDataKit

@Test
func webInspectorDataKitBaseSurfaceDoesNotRequireProxyKitImport() {
    _ = DataKitImportOnlyActor()
}

@Test
func dataKitLegacyNetworkResponseSnapshotInitializerFunctionReferenceRemainsUsable() {
    let makeResponseSnapshot = NetworkResponseSnapshot.init
    let response = makeResponseSnapshot(nil, 204, nil, nil, [:], nil, nil)

    #expect(response.status == 204)
    #expect(response.security == nil)
}

private actor DataKitImportOnlyActor {
    func consume(_ context: WebInspectorContext) async throws {
        let requests = context.network.fetchedResults()
        let messages = context.console.fetchedResults()
        let requestsByMethod: WebInspectorFetchedResults<NetworkRequest> =
            context.network.fetchedResults(for: NetworkRequestQuery(sectionBy: .method))
        let messagesByLevel: WebInspectorFetchedResults<ConsoleMessage> =
            context.console.fetchedResults(for: ConsoleMessageQuery(sectionBy: .level))
        let requestController: WebInspectorFetchedResultsController<NetworkRequest> =
            context.network.fetchedResultsController()
        let messageController: WebInspectorFetchedResultsController<ConsoleMessage> =
            context.console.fetchedResultsController()
        let networkFilters: [NetworkRequestQuery.Filter] = [
            .method(equals: "GET"),
            .method(containing: "get"),
            .url(equals: "https://example.com"),
            .url(containing: "example"),
            .searchableText(equals: "GET"),
            .searchableText(containing: "GET"),
            .mimeType(equals: nil),
            .resourceCategory(.image),
            .resourceCategories([.image, .media]),
            .statusCode(atLeast: 400),
            .statusCode(greaterThan: 399),
            .statusCode(lessThan: 500),
            .statusCode(atMost: 499),
        ]
        let networkQuery = NetworkRequestQuery(
            filter: .all(networkFilters),
            sortBy: [
                .requestSentTimestamp(order: .forward),
                .requestSentTimestamp(order: .reverse),
            ],
            sectionBy: .resourceType,
            fetchLimit: 50,
            fetchOffset: 1
        )
        _ = NetworkRequestQuery.Section.method
        _ = NetworkRequestQuery.Section.resourceCategory
        _ = NetworkRequestQuery.Section.mimeType
        _ = NetworkRequestQuery.Filter.any(networkFilters)
        let consoleFilters: [ConsoleMessageQuery.Filter] = [
            .source(.init(rawValue: "console-api")),
            .level(.init(rawValue: "warning")),
            .kind(.init(rawValue: "log")),
            .url("https://example.com/app.js"),
            .text(containing: "warning"),
        ]
        let consoleQuery = ConsoleMessageQuery(
            filter: .all(consoleFilters),
            sortBy: [
                .text(comparison: .localizedStandard, order: .forward),
                .text(comparison: .lexical, order: .reverse),
                .level(order: .forward),
                .level(order: .reverse),
            ],
            sectionBy: .source,
            fetchLimit: 50,
            fetchOffset: 1
        )
        _ = ConsoleMessageQuery.Section.level
        _ = ConsoleMessageQuery.Section.kind
        _ = ConsoleMessageQuery.Section.url
        _ = ConsoleMessageQuery.Filter.any(consoleFilters)

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
        _ = requests.items.first?.security?.connection?.tlsProtocol
        _ = requests.items.first?.security?.certificate?.dnsNames
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
        try requests.updateQuery(networkQuery)
        try messages.updateQuery(consoleQuery)
        try requests.updateQuery(NetworkRequestQuery(fetchLimit: 50))
        try requestController.updateQuery(NetworkRequestQuery(fetchOffset: 1))
        try messages.updateQuery(ConsoleMessageQuery(fetchLimit: 50))
        try messageController.updateQuery(ConsoleMessageQuery(fetchOffset: 1))
        _ = try await context.evaluate("1 + 1").object.description

        let request = NetworkRequestSnapshot(url: "https://example.com", method: "GET")
        let response = NetworkResponseSnapshot(status: 200, mimeType: "text/html")
        if let security = requests.items.first?.security {
            _ = response.reporting(security: security)
        }
        let redirect = RedirectHop(request: request, response: response, timestamp: 1)
        _ = redirect.request.url
        _ = redirect.response.status
        _ = redirect.response.security?.certificate?.subject
    }
}

import Testing
import WebInspectorDataKit

@Test
func webInspectorDataKitBaseSurfaceDoesNotRequireProxyKitImport() {
    _ = DataKitImportOnlyActor()
}

private actor DataKitImportOnlyActor {
    func consume(_ context: WebInspectorModelContext) async throws {
        let requests = try await context.networkRequests(matching: NetworkQuery(
            search: "  import-only  ",
            methods: ["GET"],
            sort: .requestTimeDescending,
            section: .initiatorNode,
            limit: 10
        ))
        let messages = try await context.consoleMessages(matching: ConsoleQuery(
            sort: .insertionDescending,
            section: .level,
            limit: 10
        ))

        _ = context.state
        _ = context.pageGeneration
        _ = try context.rootDOMNode?.children
        _ = try context.selectedDOMNode?.attributes
        _ = try context.selectedDOMNode?.attributeList.first?.name
        _ = try context.selectedDOMNode?.elementStyles?.sections.first?.rule?.selectorText
        _ = try context.selectedDOMNode?.elementStyles?.sections.first?.style.properties.first?.name
        _ = try context.selectedDOMNode?.elementStyles?.computedProperties.first?.value
        _ = try context.isElementPickerEnabled
        _ = try context.runtimeContexts.first?.name

        await context.clearNetworkRequests()
        let treeController = try context.domTree
        let treeSnapshot: DOMTreeSnapshot = treeController.snapshot
        _ = treeSnapshot.rootNodeID
        _ = treeSnapshot.nodesByID.values.first?.attributeList.first?.value
        _ = treeSnapshot.rootNodeID.map { treeSnapshot.selectorPath(for: $0) }
        _ = treeSnapshot.rootNodeID.map { treeSnapshot.xPath(for: $0) }
        _ = treeController.revision
        _ = treeController.selectedNodeID
        _ = treeController.updates
        _ = treeController.revealRequests

        if let selectedNode = try context.selectedDOMNode {
            _ = try context.selectorPath(for: selectedNode)
            _ = try context.xPath(for: selectedNode)
            _ = try await context.copyText(.selectorPath, for: selectedNode)
            try await context.highlightDOMNode(selectedNode)
            _ = try await context.removeDOMNodes([selectedNode])
        }
        try await context.hideDOMHighlight()
        try await context.setElementPickerEnabled(false)
        try await context.reload()

        _ = requests.items.first?.url
        _ = requests.items.first?.state
        _ = requests.items.first?.hasResponse
        _ = requests.items.first?.hasResponseBody
        _ = requests.items.first?.metrics
        _ = requests.sections.first?.title
        _ = requests.query
        let requestSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID, WebInspectorFetchSectionID> =
            requests.snapshot
        if let requestID = requestSnapshot.itemIDs.first {
            _ = requests[id: requestID]
        }
        if let sectionID = requestSnapshot.sectionIDs.first {
            _ = requests[section: sectionID]
        }
        let requestTransaction = WebInspectorFetchedResultsTransaction<NetworkRequest.ID>(
            oldSnapshot: requestSnapshot,
            newSnapshot: requestSnapshot,
            itemChanges: []
        )
        _ = requests.revision
        _ = requests.updates()
        try await requests.update(NetworkQuery())
        _ = requestTransaction.hasChanges
        if let request = requests.items.first {
            _ = try await context.responseBody(for: request)
        }

        _ = messages.items.first?.text
        _ = messages.items.first?.parameters.first?.description
        _ = messages.sections.first?.id
        _ = messages.query
        _ = messages.snapshot
        if let messageID = messages.snapshot.itemIDs.first {
            _ = messages[id: messageID]
        }
        if let sectionID = messages.snapshot.sectionIDs.first {
            _ = messages[section: sectionID]
        }
        _ = messages.revision
        _ = messages.updates()
        try await messages.update(ConsoleQuery())

        try await context.withRuntimeObjectGroup(named: "import-only") { group in
            let evaluation = try await group.evaluate("1 + 1")
            _ = evaluation.object.description
            _ = try await group.properties(of: evaluation.object)
            _ = try await group.preview(of: evaluation.object)
        }

        let request = NetworkRequestSnapshot(
            url: "https://example.com",
            method: "GET"
        )
        let response = NetworkResponseSnapshot(status: 200, mimeType: "text/html")
        let redirect = RedirectHop(request: request, response: response, timestamp: 1)
        _ = redirect.request.url
        _ = redirect.response.status

        consumeNetworkSection(.method)
        consumeNetworkSection(.initiatorNode)
    }

    private func consumeNetworkSection(_ section: NetworkSection) {
        switch section {
        case .method:
            break
        case .initiatorNode:
            break
        }
    }
}

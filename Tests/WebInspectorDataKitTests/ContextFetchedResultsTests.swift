import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func unfilteredNetworkInsertionsDoNotVisitExistingQueryMembership() async throws {
    let eventCount = 257
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.network.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let transactionRecorder = FetchedResultsTransactionRecorder(
        stream: controller.transactions
    )
    defer { transactionRecorder.cancel() }
    try await transactionRecorder.waitUntilStarted()
    let visitBaseline = await context.networkFullProjectionRecordVisitCountForTesting()
    let resultMaterializationBaseline = results.networkFullMembershipVisitCountForTesting
    let expectedModelIDs = (0..<eventCount).map { index in
        NetworkRequest.ID(Network.Request.ID("unfiltered-insert-\(index)"))
    }

    for index in 0..<eventCount {
        let requestID = Network.Request.ID("unfiltered-insert-\(index)")
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/\(index)",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: Double(index)
        ))
    }

    try await transactionRecorder.waitForTransactionCount(eventCount)

    let updatedIndex = eventCount / 2
    let updatedRequestID = Network.Request.ID("unfiltered-insert-\(updatedIndex)")
    await context.apply(.responseReceived(
        id: updatedRequestID,
        response: Network.Response(
            url: "https://example.test/\(updatedIndex)",
            status: 200,
            mimeType: "application/json"
        ),
        resourceType: .fetch,
        timestamp: Double(eventCount)
    ))
    await context.apply(.dataReceived(
        id: updatedRequestID,
        dataLength: 7,
        encodedDataLength: 3,
        timestamp: Double(eventCount + 1)
    ))
    await context.apply(.loadingFinished(
        id: updatedRequestID,
        timestamp: Double(eventCount + 2),
        sourceMapURL: nil,
        metrics: nil
    ))
    try await transactionRecorder.waitForTransactionCount(eventCount + 3)

    context.network.clearRequests()
    let postResetRequestID = Network.Request.ID("unfiltered-after-reset")
    await context.apply(.requestWillBeSent(
        id: postResetRequestID,
        request: Network.Request(
            id: postResetRequestID,
            url: "https://example.test/after-reset",
            method: "GET"
        ),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: Double(eventCount + 3)
    ))
    try await transactionRecorder.waitForTransactionCount(eventCount + 5)

    #expect(
        await context.networkFullProjectionRecordVisitCountForTesting() == visitBaseline
    )
    #expect(results.networkFullMembershipVisitCountForTesting == resultMaterializationBaseline)
    #expect(results.items.map(\.id.proxyID) == [postResetRequestID])

    let firstInsert = transactionRecorder.transactions[0]
    #expect(firstInsert.oldSnapshot.sections.isEmpty)
    #expect(firstInsert.newSnapshot.itemIDs == [expectedModelIDs[0]])
    #expect(firstInsert.sectionChanges == [
        .insert(sectionID: .defaultSection, index: 0),
    ])

    let lastInsert = transactionRecorder.transactions[eventCount - 1]
    #expect(lastInsert.oldSnapshot.itemIDs == Array(expectedModelIDs.dropLast()))
    #expect(lastInsert.newSnapshot.itemIDs == expectedModelIDs)

    let expectedUpdateChanges: [WebInspectorFetchedResultsItemChange<NetworkRequest.ID>] = [
        .update(
            itemID: expectedModelIDs[updatedIndex],
            indexPath: WebInspectorFetchedResultsIndexPath(
                section: 0,
                item: updatedIndex
            )
        ),
    ]
    for update in transactionRecorder.transactions[eventCount..<(eventCount + 3)] {
        #expect(update.oldSnapshot.itemIDs == expectedModelIDs)
        #expect(update.newSnapshot.itemIDs == expectedModelIDs)
        #expect(update.itemChanges == expectedUpdateChanges)
    }

    let reset = transactionRecorder.transactions[eventCount + 3]
    #expect(reset.isReset)
    #expect(reset.oldSnapshot.itemIDs == expectedModelIDs)
    #expect(reset.newSnapshot.sections.isEmpty)

    let postResetInsert = transactionRecorder.transactions[eventCount + 4]
    #expect(postResetInsert.oldSnapshot.sections.isEmpty)
    #expect(postResetInsert.newSnapshot.itemIDs == [NetworkRequest.ID(postResetRequestID)])
    #expect(lastInsert.newSnapshot.itemIDs == expectedModelIDs)
}

@MainActor
@Test
func fetchedResultsControllerPublishesNetworkInsertAndContentUpdateTransactions() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.network.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let requestID = Network.Request.ID("controller-request")
    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/first", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(1)
    let inserted = try #require(recorder.transactions.last)
    let modelID = NetworkRequest.ID(requestID)
    let firstIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
    #expect(inserted.itemChanges == [.insert(itemID: modelID, indexPath: firstIndexPath)])
    #expect(inserted.oldSnapshot.itemIDs == [])
    #expect(inserted.newSnapshot.itemIDs == [modelID])
    #expect(controller.snapshot.itemIDs == [modelID])
    let request = try #require(results.items.first)

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(status: 200, statusText: "OK", mimeType: "text/plain"),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { request.status == 200 }
    try await recorder.waitForTransactionCount(2)
    #expect(results.items.first === request)
    let responseUpdate = try #require(recorder.transactions.last)
    #expect(responseUpdate.oldSnapshot == responseUpdate.newSnapshot)
    #expect(responseUpdate.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    await runtime.backend.emit(
        .dataReceived(id: requestID, dataLength: 7, encodedDataLength: 3, timestamp: 3),
        target: target
    )

    try await waitUntil { request.decodedDataLength == 7 && request.encodedDataLength == 3 }
    try await recorder.waitForTransactionCount(3)
    #expect(results.items.first === request)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    await runtime.backend.emit(
        .loadingFinished(id: requestID, timestamp: 4, sourceMapURL: nil, metrics: nil),
        target: target
    )

    try await waitUntil { request.state == .finished }
    try await recorder.waitForTransactionCount(4)
    #expect(results.items.first === request)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    await runtime.backend.emit(
        .requestServedFromMemoryCache(
            id: requestID,
            response: Network.Response(url: "https://example.com/first", status: 200),
            resourceType: nil,
            timestamp: 5
        ),
        target: target
    )

    try await waitUntil { request.finishedOrFailedTimestamp == 5 }
    try await recorder.waitForTransactionCount(5)
    #expect(results.items.first === request)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: modelID, indexPath: firstIndexPath)])

    let failedRequestID = Network.Request.ID("controller-failed-request")
    let failedModelID = NetworkRequest.ID(failedRequestID)
    let failedIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: failedRequestID,
            request: Network.Request(id: failedRequestID, url: "https://example.com/failed", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 6
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(6)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: failedModelID, indexPath: failedIndexPath)])
    let failedRequest = try #require(results.items.last)

    await runtime.backend.emit(
        .loadingFailed(id: failedRequestID, errorText: "cancelled", canceled: true, timestamp: 7),
        target: target
    )

    try await waitUntil {
        if case .failed(errorText: "cancelled", canceled: true) = failedRequest.state {
            return true
        }
        return false
    }
    try await recorder.waitForTransactionCount(7)
    #expect(results.items.last === failedRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: failedModelID, indexPath: failedIndexPath)])

    let socketRequestID = Network.Request.ID("controller-socket-request")
    let socketModelID = NetworkRequest.ID(socketRequestID)
    let socketIndexPath = WebInspectorFetchedResultsIndexPath(section: 0, item: 2)
    await runtime.backend.emit(
        .webSocket(.created(id: socketRequestID, url: "wss://example.com/socket")),
        target: target
    )

    try await recorder.waitForTransactionCount(8)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: socketModelID, indexPath: socketIndexPath)])
    let socketRequest = try #require(results.items.last)

    await runtime.backend.emit(
        .webSocket(.handshakeRequest(
            id: socketRequestID,
            request: Network.Request(
                id: socketRequestID,
                url: "wss://example.com/socket",
                method: "GET",
                headers: ["Upgrade": "websocket"]
            ),
            timestamp: 8
        )),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.handshakeRequest?.headers["Upgrade"] == "websocket" }
    try await recorder.waitForTransactionCount(9)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
        .webSocket(.handshakeResponse(
            id: socketRequestID,
            response: Network.Response(status: 101, statusText: "Switching Protocols"),
            timestamp: 9
        )),
        target: target
    )

    try await waitUntil { socketRequest.status == 101 }
    try await recorder.waitForTransactionCount(10)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
        .webSocket(.frameSent(
            id: socketRequestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5),
            timestamp: 10
        )),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 1 }
    try await recorder.waitForTransactionCount(11)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
        .webSocket(.frameReceived(
            id: socketRequestID,
            frame: Network.WebSocketFrame(opcode: 1, mask: false, payloadData: "world", payloadLength: 5),
            timestamp: 11
        )),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 2 }
    try await recorder.waitForTransactionCount(12)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
        .webSocket(.error(id: socketRequestID, message: "decode failed", timestamp: 12)),
        target: target
    )

    try await waitUntil { socketRequest.webSocket?.frames.count == 3 }
    try await recorder.waitForTransactionCount(13)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])

    await runtime.backend.emit(
        .webSocket(.closed(id: socketRequestID, timestamp: 13)),
        target: target
    )

    try await waitUntil { socketRequest.state == .finished && socketRequest.webSocket?.readyState == .closed }
    try await recorder.waitForTransactionCount(14)
    #expect(results.items.last === socketRequest)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: socketModelID, indexPath: socketIndexPath)])
}

@MainActor
@Test
func unfilteredNetworkContentUpdateDoesNotVisitFullMembership() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    for index in 0..<2_305 {
        let requestID = Network.Request.ID("request-\(index)")
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/\(index)",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: Double(index)
        ))
    }

    let results: WebInspectorFetchedResults<NetworkRequest> = context.network.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()
    let membershipVisitBaseline = results.networkFullMembershipVisitCountForTesting
    let updatedIndex = 1_152
    let requestID = Network.Request.ID("request-\(updatedIndex)")

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            url: "https://example.test/\(updatedIndex)",
            status: 201,
            statusText: "Created",
            mimeType: "application/json"
        ),
        resourceType: .fetch,
        timestamp: 3_000
    ))

    try await recorder.waitForTransactionCount(1)
    #expect(results.networkFullMembershipVisitCountForTesting == membershipVisitBaseline)
    #expect(recorder.transactions.last?.itemChanges == [
        .update(
            itemID: NetworkRequest.ID(requestID),
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: updatedIndex)
        ),
    ])
}

@MainActor
@Test
func sectionedNetworkResultsPublishTopologyWhenSectionKeyChanges() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results = context.network.fetchedResults(for: NetworkRequestQuery(sectionBy: .mimeType))
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let requestID = Network.Request.ID("sectioned-controller-request")
    let modelID = NetworkRequest.ID(requestID)
    await runtime.backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://media.example.com/clip.mp4", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(1)
    #expect(controller.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "")])
    #expect(controller.snapshot.itemIDs == [modelID])

    await runtime.backend.emit(
        .responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://media.example.com/clip.mp4",
                status: 200,
                mimeType: "video/mp4"
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(2)
    let sectionChange = try #require(recorder.transactions.last)
    #expect(sectionChange.isReset == false)
    #expect(sectionChange.oldSnapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "")])
    #expect(sectionChange.newSnapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "video/mp4")])
    #expect(sectionChange.oldSnapshot.itemIDs == [modelID])
    #expect(sectionChange.newSnapshot.itemIDs == [modelID])
    #expect(sectionChange.sectionChanges == [
        .delete(sectionID: WebInspectorFetchSectionID(rawValue: ""), index: 0),
        .insert(sectionID: WebInspectorFetchSectionID(rawValue: "video/mp4"), index: 0),
    ])
    #expect(sectionChange.itemChanges == [])
}

@MainActor
@Test
func sectionedNetworkResultsPublishItemMoveWhenSectionKeyChangesBetweenExistingSections() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results = context.network.fetchedResults(
        for: NetworkRequestQuery(sectionBy: .resourceCategory)
    )
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let imageID = Network.Request.ID("existing-image-section")
    let movingID = Network.Request.ID("moving-xhr-to-image")
    let remainingXHRID = Network.Request.ID("remaining-xhr-section")
    await context.apply(.requestWillBeSent(
        id: imageID,
        request: Network.Request(id: imageID, url: "https://cdn.example.com/photo.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: movingID,
        request: Network.Request(id: movingID, url: "https://api.example.com/avatar", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.requestWillBeSent(
        id: remainingXHRID,
        request: Network.Request(id: remainingXHRID, url: "https://api.example.com/data", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 3
    ))
    try await recorder.waitForTransactionCount(3)

    let movingModelID = NetworkRequest.ID(movingID)
    await context.apply(.responseReceived(
        id: movingID,
        response: Network.Response(
            url: "https://api.example.com/avatar",
            status: 200,
            mimeType: "image/png"
        ),
        resourceType: .xhr,
        timestamp: 4
    ))

    try await recorder.waitForTransactionCount(4)
    #expect(controller.snapshot.sections.map(\.id) == [
        WebInspectorFetchSectionID(rawValue: "image"),
        WebInspectorFetchSectionID(rawValue: "xhrFetch"),
    ])
    #expect(controller.snapshot.sections.map(\.itemIDs) == [
        [NetworkRequest.ID(imageID), movingModelID],
        [NetworkRequest.ID(remainingXHRID)],
    ])
    #expect(recorder.transactions.last?.itemChanges == [
        .move(
            itemID: movingModelID,
            from: WebInspectorFetchedResultsIndexPath(section: 1, item: 0),
            to: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
        ),
    ])
}

@MainActor
@Test
func networkQueryAppliesFilterSortAndLimit() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("graphql-old"),
        request: Network.Request(id: Network.Request.ID("graphql-old"), url: "https://api.example.com/graphql?older", method: "POST"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("image"),
        request: Network.Request(id: Network.Request.ID("image"), url: "https://static.example.com/photo.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("graphql-new"),
        request: Network.Request(id: Network.Request.ID("graphql-new"), url: "https://api.example.com/graphql?newer", method: "POST"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 3
    ))

    let xhrFetch = NetworkRequest.ResourceCategory.xhrFetch
    let search = "graphql"
    let query = NetworkRequestQuery(
        filter: .all([
            .resourceCategory(xhrFetch),
            .searchableText(containing: search),
        ]),
        sortBy: [.requestSentTimestamp(order: .reverse)],
        fetchLimit: 1
    )

    let results = context.network.fetchedResults(for: query)

    #expect(results.items.map(\.id) == [NetworkRequest.ID(Network.Request.ID("graphql-new"))])
}

@MainActor
@Test
func networkQueryCombinesURLAndMIMETypeFilters() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("api"),
        request: Network.Request(id: Network.Request.ID("api"), url: "https://api.example.com/data.json", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("image"),
        request: Network.Request(id: Network.Request.ID("image"), url: "https://static.example.com/photo", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.responseReceived(
        id: Network.Request.ID("image"),
        response: Network.Response(
            url: "https://static.example.com/photo",
            status: 200,
            mimeType: "image/png"
        ),
        resourceType: .image,
        timestamp: 3
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("script"),
        request: Network.Request(id: Network.Request.ID("script"), url: "https://cdn.example.com/app.js", method: "GET"),
        resourceType: .script,
        redirectResponse: nil,
        timestamp: 4
    ))

    let query = NetworkRequestQuery(
        filter: .any([
            .url(containing: "api"),
            .mimeType(equals: "image/png"),
        ]),
        sortBy: [.requestSentTimestamp(order: .forward)]
    )
    let results = context.network.fetchedResults(for: query)

    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("api")),
        NetworkRequest.ID(Network.Request.ID("image")),
    ])
}

@MainActor
@Test
func clearNetworkRequestsResetsConfiguredQueryState() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let query = NetworkRequestQuery(
        sortBy: [.requestSentTimestamp(order: .forward)],
        fetchLimit: 2
    )
    let results = context.network.fetchedResults(for: query)

    for (index, name) in ["stale-a", "stale-b", "stale-c"].enumerated() {
        await context.apply(.requestWillBeSent(
            id: Network.Request.ID(name),
            request: Network.Request(id: Network.Request.ID(name), url: "https://example.com/\(name)", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: Double(index + 1)
        ))
    }
    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("stale-a")),
        NetworkRequest.ID(Network.Request.ID("stale-b")),
    ])

    context.clearNetworkRequests()
    #expect(results.items.isEmpty)

    let freshID = Network.Request.ID("fresh-after-clear")
    await context.apply(.requestWillBeSent(
        id: freshID,
        request: Network.Request(id: freshID, url: "https://example.com/fresh", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 10
    ))

    #expect(results.items.map(\.id) == [NetworkRequest.ID(freshID)])
}

@MainActor
@Test
func startResetsConfiguredNetworkQueryState() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let query = NetworkRequestQuery(
        sortBy: [.requestSentTimestamp(order: .forward)],
        fetchLimit: 1
    )
    let networkResults = context.network.fetchedResults(for: query)
    let staleRequestID = Network.Request.ID("stale-query-before-restart")

    await emitFinishedRequest(id: staleRequestID, target: target, backend: runtime.backend)
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(staleRequestID)]
    }

    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("fresh-query-root"), nodeType: 9, nodeName: "#document")
    )

    context.start()

    try await waitUntil(in: context) {
        networkResults.items.isEmpty && context.state == .attached
    }

    let freshRequestID = Network.Request.ID("fresh-query-after-restart")
    await emitFinishedRequest(id: freshRequestID, target: target, backend: runtime.backend)
    try await waitUntil {
        networkResults.items.map(\.id) == [NetworkRequest.ID(freshRequestID)]
    }
}

@MainActor
@Test
func networkQueryOrdersEqualTimestampsByNewestInsertionFirst() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let query = NetworkRequestQuery(
        sortBy: [.requestSentTimestamp(order: .reverse)]
    )
    let results = context.network.fetchedResults(for: query)
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let firstID = Network.Request.ID("same-timestamp-first")
    let secondID = Network.Request.ID("same-timestamp-second")
    let firstModelID = NetworkRequest.ID(firstID)
    let secondModelID = NetworkRequest.ID(secondID)

    await context.apply(.requestWillBeSent(
        id: firstID,
        request: Network.Request(id: firstID, url: "https://example.com/first", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    try await recorder.waitForTransactionCount(1)
    #expect(results.items.map(\.id) == [firstModelID])

    await context.apply(.requestWillBeSent(
        id: secondID,
        request: Network.Request(id: secondID, url: "https://example.com/second", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))

    try await recorder.waitForTransactionCount(2)
    #expect(results.items.map(\.id) == [secondModelID, firstModelID])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(itemID: secondModelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])
}

@MainActor
@Test
func networkQueryPublishesFilterEnterAndLeave() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let query = NetworkRequestQuery(
        filter: .statusCode(atLeast: 400)
    )
    let results = context.network.fetchedResults(for: query)
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let requestID = Network.Request.ID("status-request")
    let modelID = NetworkRequest.ID(requestID)
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(id: requestID, url: "https://api.example.com/status", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 1
    ))
    #expect(results.items.isEmpty)
    #expect(recorder.transactions.isEmpty)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(url: "https://api.example.com/status", status: 500),
        resourceType: .fetch,
        timestamp: 2
    ))

    try await recorder.waitForTransactionCount(1)
    #expect(results.items.map(\.id) == [modelID])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(itemID: modelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(url: "https://api.example.com/status", status: 200),
        resourceType: .fetch,
        timestamp: 3
    ))

    try await recorder.waitForTransactionCount(2)
    #expect(results.items.isEmpty)
    #expect(recorder.transactions.last?.itemChanges == [
        .delete(itemID: modelID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])
    #expect(context.registeredRequest(for: modelID) != nil)
}

@MainActor
@Test
func networkQuerySupportsResourceCategorySets() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)

    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("pending-avatar"),
        request: Network.Request(id: Network.Request.ID("pending-avatar"), url: "https://api.example.com/avatar.png", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 1
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("script"),
        request: Network.Request(id: Network.Request.ID("script"), url: "https://cdn.example.com/app.js", method: "GET"),
        resourceType: .script,
        redirectResponse: nil,
        timestamp: 2
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("image"),
        request: Network.Request(id: Network.Request.ID("image"), url: "https://cdn.example.com/photo.png", method: "GET"),
        resourceType: .image,
        redirectResponse: nil,
        timestamp: 3
    ))
    await context.apply(.requestWillBeSent(
        id: Network.Request.ID("movie"),
        request: Network.Request(id: Network.Request.ID("movie"), url: "https://media.example.com/clip.mp4", method: "GET"),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: 4
    ))

    let mediaCategories: [NetworkRequest.ResourceCategory] = [.image, .media]
    let query = NetworkRequestQuery(
        filter: .resourceCategories(mediaCategories),
        sortBy: [.requestSentTimestamp(order: .reverse)]
    )
    let results = context.network.fetchedResults(for: query)

    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("image")),
    ])

    await context.apply(.responseReceived(
        id: Network.Request.ID("pending-avatar"),
        response: Network.Response(
            url: "https://api.example.com/avatar.png",
            status: 200,
            mimeType: "image/png"
        ),
        resourceType: .xhr,
        timestamp: 5
    ))
    await context.apply(.responseReceived(
        id: Network.Request.ID("movie"),
        response: Network.Response(
            url: "https://media.example.com/clip.mp4",
            status: 200,
            mimeType: "application/octet-stream"
        ),
        resourceType: .fetch,
        timestamp: 6
    ))

    #expect(results.items.map(\.id) == [
        NetworkRequest.ID(Network.Request.ID("movie")),
        NetworkRequest.ID(Network.Request.ID("image")),
        NetworkRequest.ID(Network.Request.ID("pending-avatar")),
    ])
}

@MainActor
@Test
func networkRequestResourceCategoryUsesResponseHeadersWithoutPendingURLInference() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let requestID = Network.Request.ID("header-avatar")
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(id: requestID, url: "https://api.example.com/avatar.png", method: "GET"),
        resourceType: .xhr,
        redirectResponse: nil,
        timestamp: 1
    ))
    let request = try #require(context.registeredRequest(forProxyID: requestID))

    #expect(request.resourceCategory == .xhrFetch)

    await context.apply(.responseReceived(
        id: requestID,
        response: Network.Response(
            url: "https://api.example.com/avatar",
            status: 200,
            mimeType: nil,
            headers: ["Content-Type": "image/png; charset=utf-8"]
        ),
        resourceType: .xhr,
        timestamp: 2
    ))

    #expect(request.resourceCategory == .image)
    #expect(request.searchableText.localizedStandardContains("image/png") == false)

    let scriptVideoID = Network.Request.ID("script-video")
    await context.apply(.requestWillBeSent(
        id: scriptVideoID,
        request: Network.Request(id: scriptVideoID, url: "https://cdn.example.com/player.js", method: "GET"),
        resourceType: .script,
        redirectResponse: nil,
        timestamp: 3
    ))
    let scriptVideoRequest = try #require(context.registeredRequest(forProxyID: scriptVideoID))
    #expect(scriptVideoRequest.resourceCategory == .script)

    await context.apply(.responseReceived(
        id: scriptVideoID,
        response: Network.Response(
            url: "https://cdn.example.com/player.js",
            status: 200,
            mimeType: "video/mp4"
        ),
        resourceType: .script,
        timestamp: 4
    ))

    #expect(scriptVideoRequest.resourceCategory == .media)
}

@MainActor
@Test
func networkRequestExposesDataKitQueryableProperties() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<NetworkRequest> = context.network.fetchedResults()

    let apiRequestID = Network.Request.ID("queryable-api-request")
    await runtime.backend.emit(
        .requestWillBeSent(
            id: apiRequestID,
            request: Network.Request(
                id: apiRequestID,
                url: "https://api.example.test/graphql?operation=Feed",
                method: "POST"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await runtime.backend.emit(
        .responseReceived(
            id: apiRequestID,
            response: Network.Response(
                url: "https://api.example.test/graphql?operation=Feed",
                status: 201,
                statusText: "Created",
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )

    try await waitUntil { results.items.first?.statusCode == 201 }
    let apiRequest = try #require(results.items.first)
    #expect(apiRequest.resourceCategory == .xhrFetch)
    #expect(apiRequest.statusCode == 201)
    #expect(apiRequest.searchableText.localizedStandardContains("graphql"))
    #expect(apiRequest.searchableText.localizedStandardContains("POST"))
    #expect(apiRequest.searchableText.localizedStandardContains("201"))
    #expect(apiRequest.searchableText.localizedStandardContains("Created"))

    let cssRequestID = Network.Request.ID("queryable-css-request")
    await runtime.backend.emit(
        .responseReceived(
            id: cssRequestID,
            response: Network.Response(
                url: "https://example.test/app.css",
                status: 200,
                mimeType: "text/css; charset=utf-8"
            ),
            resourceType: .other,
            timestamp: 3
        ),
        target: target
    )

    try await waitUntil { results.items.count == 2 }
    let cssRequest = try #require(results.items.last)
    #expect(cssRequest.resourceCategory == .stylesheet)
    #expect(cssRequest.searchableText.localizedStandardContains("app.css"))
    #expect(cssRequest.statusCode == 200)
}

@MainActor
@Test
func fetchedResultsControllerPublishesConsoleInsertUpdateAndDeleteTransactions() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first"
        )),
        target: target
    )

    try await recorder.waitForTransactionCount(1)
    let firstID = try #require(controller.snapshot.itemIDs.first)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])

    await runtime.backend.emit(
        .messageRepeatCountUpdated(count: 3, timestamp: 2),
        target: target
    )

    try await recorder.waitForTransactionCount(2)
    #expect(recorder.transactions.last?.itemChanges == [.update(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0))])

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second"
        )),
        target: target
    )

    try await recorder.waitForTransactionCount(3)
    let secondID = try #require(controller.snapshot.itemIDs.last)
    #expect(recorder.transactions.last?.itemChanges == [.insert(itemID: secondID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1))])

    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )

    try await recorder.waitForTransactionCount(4)
    #expect(recorder.transactions.last?.itemChanges == [
        .delete(itemID: secondID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)),
        .delete(itemID: firstID, indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
    ])
    #expect(controller.snapshot.itemIDs == [])
}

@MainActor
@Test
func networkResultsCanBeSectionedByMethod() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results = context.network.fetchedResults(for: NetworkRequestQuery(sectionBy: .method))
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    let recorder = FetchedResultsTransactionRecorder(stream: controller.transactions)
    defer { recorder.cancel() }
    try await recorder.waitUntilStarted()

    let getID = Network.Request.ID("sectioned-get")
    await runtime.backend.emit(
        .requestWillBeSent(
            id: getID,
            request: Network.Request(id: getID, url: "https://example.com/get", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(1)
    #expect(results.sections.map(\.title) == ["GET"])
    #expect(controller.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "GET")])
    #expect(recorder.transactions.last?.sectionChanges == [
        .insert(sectionID: WebInspectorFetchSectionID(rawValue: "GET"), index: 0)
    ])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(
            itemID: NetworkRequest.ID(getID),
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
        )
    ])

    let postID = Network.Request.ID("sectioned-post")
    await runtime.backend.emit(
        .requestWillBeSent(
            id: postID,
            request: Network.Request(id: postID, url: "https://example.com/post", method: "POST"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(2)
    #expect(results.sections.map(\.title) == ["GET", "POST"])
    #expect(recorder.transactions.last?.sectionChanges == [
        .insert(sectionID: WebInspectorFetchSectionID(rawValue: "POST"), index: 1)
    ])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(
            itemID: NetworkRequest.ID(postID),
            indexPath: WebInspectorFetchedResultsIndexPath(section: 1, item: 0)
        )
    ])

    let secondGetID = Network.Request.ID("sectioned-second-get")
    await runtime.backend.emit(
        .requestWillBeSent(
            id: secondGetID,
            request: Network.Request(id: secondGetID, url: "https://example.com/get-2", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 3
        ),
        target: target
    )

    try await recorder.waitForTransactionCount(3)
    #expect(results.sections.map(\.items.count) == [2, 1])
    #expect(recorder.transactions.last?.sectionChanges == [])
    #expect(recorder.transactions.last?.itemChanges == [
        .insert(
            itemID: NetworkRequest.ID(secondGetID),
            indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
        )
    ])
}

@MainActor
@Test
func consoleResultsCanBeSectionedByLevel() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results = context.console.fetchedResults(for: ConsoleMessageQuery(sectionBy: .level))

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "warning"
        )),
        target: target
    )

    try await waitUntil { results.sections.first?.title == "warning" }
    #expect(results.sections.map(\.id) == [WebInspectorFetchSectionID(rawValue: "warning")])
    #expect(results.sections.first?.items.first?.text == "warning")
}

@MainActor
@Test
func fetchedResultsTransactionDiffsMovesByItemID() {
    let first = NetworkRequest.ID(Network.Request.ID("first"))
    let second = NetworkRequest.ID(Network.Request.ID("second"))
    let oldSnapshot = WebInspectorFetchedResultsSnapshot(itemIDs: [first, second])
    let newSnapshot = WebInspectorFetchedResultsSnapshot(itemIDs: [second, first])

    let transaction = WebInspectorFetchedResultsTransaction<NetworkRequest>(
        oldSnapshot: oldSnapshot,
        newSnapshot: newSnapshot
    )

    #expect(transaction.itemChanges == [
        .move(itemID: second, from: WebInspectorFetchedResultsIndexPath(section: 0, item: 1), to: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)),
        .move(itemID: first, from: WebInspectorFetchedResultsIndexPath(section: 0, item: 0), to: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)),
    ])
}

@MainActor
@Test
func consoleFetchedResultsHonorQueriesForInitialUpdatesAndQueryChanges() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let allResults = context.console.fetchedResults()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "middle"
        )),
        target: target
    )
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "error"),
            text: "zeta"
        )),
        target: target
    )
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "omega"
        )),
        target: target
    )
    try await waitUntil { allResults.items.count == 3 }

    let warningQuery = ConsoleMessageQuery(
        filter: .level(Console.Level(rawValue: "warning")),
        sortBy: [.text(order: .reverse)],
        fetchLimit: 2
    )
    let warningResults = context.console.fetchedResults(for: warningQuery)

    #expect(warningResults.items.map(\.text) == ["omega", "middle"])

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "zebra"
        )),
        target: target
    )
    try await waitUntil {
        warningResults.items.map(\.text) == ["zebra", "omega"]
    }

    try warningResults.updateQuery(ConsoleMessageQuery(
        sortBy: [.text()],
        fetchLimit: 2,
        fetchOffset: 1
    ))

    try await waitUntil {
        warningResults.items.map(\.text) == ["omega", "zebra"]
    }
}

@MainActor
@Test
func consoleFetchedResultsPreserveTieOrderAndCustomComparators() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    for text in ["item2", "item10"] {
        context.apply(.messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: text
        )))
    }

    let reverseTieResults: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults(
        for: ConsoleMessageQuery(
            sortBy: [.level(order: .reverse)],
            fetchLimit: 1
        )
    )
    let lexicalResults: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults(
        for: ConsoleMessageQuery(
            sortBy: [.text(comparison: .lexical)]
        )
    )

    #expect(reverseTieResults.items.map(\.text) == ["item2"])
    #expect(lexicalResults.items.map(\.text) == ["item10", "item2"])
}

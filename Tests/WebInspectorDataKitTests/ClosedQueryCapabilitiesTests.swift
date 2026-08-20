import Foundation
import Observation
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func networkFilterFactoriesMatchTheirDocumentedCapabilities() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let id = context.seedNetworkRequest(
        requestID: "closed-network-filter",
        url: "https://api.example.test/graphql",
        method: "POST",
        resourceTypeRawValue: "Image",
        responseMIMEType: "image/png",
        responseStatus: 404,
        responseStatusText: "Not Found",
        timestamp: 1
    )
    let request = try #require(context.registeredRequest(for: id))
    let record = NetworkRequestRecord(request: request, orderIndex: 0)

    let matchingFilters: [NetworkRequestQuery.Filter] = [
        .method(equals: "POST"),
        .method(containing: "post"),
        .url(equals: request.url),
        .url(containing: "API"),
        .searchableText(equals: request.searchableText),
        .searchableText(containing: "graphql"),
        .mimeType(equals: "image/png"),
        .resourceCategory(request.resourceCategory),
        .resourceCategories([.image, .media]),
        .statusCode(atLeast: 400),
        .statusCode(greaterThan: 403),
        .statusCode(lessThan: 405),
        .statusCode(atMost: 404),
        .all([.method(equals: "POST"), .statusCode(atLeast: 400)]),
        .any([.method(equals: "GET"), .statusCode(atLeast: 400)]),
    ]
    #expect(matchingFilters.allSatisfy { $0.matches(record: record) })
    #expect(NetworkRequestQuery.Filter.statusCode(greaterThan: 404).matches(record: record) == false)
    #expect(NetworkRequestQuery.Filter.statusCode(lessThan: 404).matches(record: record) == false)
    #expect(NetworkRequestQuery.Filter.statusCode(atLeast: 404).matches(record: record))
    #expect(NetworkRequestQuery.Filter.statusCode(atMost: 404).matches(record: record))
    #expect(NetworkRequestQuery.Filter.all([]).matches(record: record))
    #expect(NetworkRequestQuery.Filter.any([]).matches(record: record) == false)

    let pendingID = Network.Request.ID("closed-network-missing-status")
    await context.apply(
        .requestWillBeSent(
            id: pendingID,
            request: Network.Request(id: pendingID, url: "https://example.test/pending", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ))
    let pending = try #require(context.registeredRequest(for: NetworkRequest.ID(pendingID)))
    let pendingRecord = NetworkRequestRecord(request: pending, orderIndex: 1)
    #expect(NetworkRequestQuery.Filter.statusCode(atLeast: 500).matches(record: pendingRecord) == false)
    #expect(
        NetworkRequestQuery.Filter.statusCode(atLeast: 500, whenMissing: 500)
            .matches(record: pendingRecord)
    )
}

@MainActor
@Test
func consoleFilterFactoriesAndSortsMatchTheirDocumentedCapabilities() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    context.apply(
        .messageAdded(
            Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                text: "Alpha warning"
            )))
    context.apply(
        .messageAdded(
            Console.Message(
                source: Console.Source(rawValue: "javascript"),
                level: Console.Level(rawValue: "error"),
                text: "beta error"
            )))
    let all = context.console.fetchedResults().items
    let warning = try #require(all.first)
    let error = try #require(all.last)

    let matchingFilters: [ConsoleMessageQuery.Filter] = [
        .source(warning.source),
        .level(warning.level),
        .kind(nil),
        .url(nil),
        .text(containing: "warning"),
        .all([.source(warning.source), .level(warning.level)]),
        .any([.level(error.level), .text(containing: "Alpha")]),
    ]
    #expect(matchingFilters.allSatisfy { $0.matches(warning) })
    #expect(ConsoleMessageQuery.Filter.all([]).matches(warning))
    #expect(ConsoleMessageQuery.Filter.any([]).matches(warning) == false)

    #expect(ConsoleMessageQuery.Sort.text().compare(warning, error) == .orderedAscending)
    #expect(
        ConsoleMessageQuery.Sort.text(comparison: .lexical, order: .reverse)
            .compare(warning, error) == .orderedDescending
    )
    let levelForward = ConsoleMessageQuery.Sort.level().compare(warning, error)
    let levelReverse = ConsoleMessageQuery.Sort.level(order: .reverse).compare(warning, error)
    #expect(levelForward != .orderedSame)
    #expect(levelReverse != .orderedSame)
    #expect(levelForward != levelReverse)
}

@MainActor
@Test
func everyClosedSectionCapabilityProducesCurrentSections() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    context.seedNetworkRequest(
        requestID: "closed-section-request",
        url: "https://example.test/image.png",
        method: "GET",
        resourceTypeRawValue: "Image",
        responseMIMEType: "image/png",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 1
    )
    context.apply(
        .messageAdded(
            Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "warning"),
                type: Console.Kind(rawValue: "log"),
                text: "sectioned",
                url: "https://example.test/app.js"
            )))

    for (section, expectedID) in [
        (NetworkRequestQuery.Section.method, "GET"),
        (.resourceType, "Image"),
        (.resourceCategory, "image"),
        (.mimeType, "image/png"),
    ] {
        let results = context.network.fetchedResults(for: NetworkRequestQuery(sectionBy: section))
        #expect(results.sections.map(\.id.rawValue) == [expectedID])
    }
    for (section, expectedID) in [
        (ConsoleMessageQuery.Section.source, "console-api"),
        (.level, "warning"),
        (.kind, "log"),
        (.url, "https://example.test/app.js"),
    ] {
        let results = context.console.fetchedResults(for: ConsoleMessageQuery(sectionBy: section))
        #expect(results.sections.map(\.id.rawValue) == [expectedID])
    }
}

@MainActor
@Test
func closedNetworkQueryPublishesOnlyVisibleContentUpdatesExactlyOnce() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let results = context.network.fetchedResults(
        for: NetworkRequestQuery(
            filter: .method(equals: "GET"),
            sortBy: [.requestSentTimestamp()],
            fetchLimit: 2
        )
    )
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    var transactions = controller.transactions.makeAsyncIterator()
    let firstID = Network.Request.ID("closed-visible-first")
    let filteredID = Network.Request.ID("closed-filtered")
    let secondID = Network.Request.ID("closed-visible-second")
    let outsideWindowID = Network.Request.ID("closed-outside-window")

    await context.apply(
        .requestWillBeSent(
            id: firstID,
            request: Network.Request(
                id: firstID,
                url: "https://example.test/first",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .insert(
                itemID: NetworkRequest.ID(firstID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])

    await context.apply(
        .requestWillBeSent(
            id: filteredID,
            request: Network.Request(
                id: filteredID,
                url: "https://example.test/filtered",
                method: "POST"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 2
        ))
    await context.apply(
        .requestWillBeSent(
            id: secondID,
            request: Network.Request(
                id: secondID,
                url: "https://example.test/second",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 3
        ))
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .insert(
                itemID: NetworkRequest.ID(secondID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])

    await context.apply(
        .requestWillBeSent(
            id: outsideWindowID,
            request: Network.Request(
                id: outsideWindowID,
                url: "https://example.test/outside",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 4
        ))
    await context.apply(
        .responseReceived(
            id: firstID,
            response: Network.Response(
                url: "https://example.test/first",
                status: 201,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 5
        ))
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: NetworkRequest.ID(firstID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])

    await context.apply(
        .responseReceived(
            id: filteredID,
            response: Network.Response(
                url: "https://example.test/filtered",
                status: 202
            ),
            resourceType: .fetch,
            timestamp: 6
        ))
    await context.apply(
        .dataReceived(
            id: outsideWindowID,
            dataLength: 7,
            encodedDataLength: 7,
            timestamp: 7
        ))
    await context.apply(
        .responseReceived(
            id: secondID,
            response: Network.Response(
                url: "https://example.test/second",
                status: 203
            ),
            resourceType: .fetch,
            timestamp: 8
        ))
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: NetworkRequest.ID(secondID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])

    await context.apply(
        .dataReceived(
            id: firstID,
            dataLength: 9,
            encodedDataLength: 9,
            timestamp: 9
        ))
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: NetworkRequest.ID(firstID),
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])
    #expect(results.items.map(\.id) == [NetworkRequest.ID(firstID), NetworkRequest.ID(secondID)])
}

@MainActor
@Test
func contentOnlyNetworkDeltaKeepsMaterializedTopologyAndLookupWorkUnchanged() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let visibleID = context.seedNetworkRequest(
        requestID: "closed-index-visible",
        url: "https://example.test/visible",
        method: "GET",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 1
    )
    let filteredID = context.seedNetworkRequest(
        requestID: "closed-index-filtered",
        url: "https://example.test/filtered",
        method: "POST",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 2
    )
    let visibleRequest = try #require(context.registeredRequest(for: visibleID))
    let filteredRequest = try #require(context.registeredRequest(for: filteredID))
    let query = NetworkRequestQuery(filter: .method(equals: "GET"))
    let plan = NetworkRequestQueryPlan(query: query)
    let index = NetworkRequestIndex()
    await index.replace(
        with: [
            NetworkRequestRecordInput(request: visibleRequest, orderIndex: 0),
            NetworkRequestRecordInput(request: filteredRequest, orderIndex: 1),
        ],
        sequence: 1
    )
    let oldSnapshot = WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>(
        itemIDs: [visibleID]
    )
    let delta = try #require(
        await index.delta(
            plan: plan,
            sectionBy: nil,
            oldSnapshot: oldSnapshot,
            changedID: visibleID
        ))
    #expect(delta.snapshot == oldSnapshot)
    #expect(delta.transaction.oldSnapshot == oldSnapshot)
    #expect(delta.transaction.newSnapshot == oldSnapshot)
    #expect(
        delta.transaction.itemChanges == [
            .update(
                itemID: visibleID,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])
    #expect(
        await index.delta(
            plan: plan,
            sectionBy: nil,
            oldSnapshot: oldSnapshot,
            changedID: filteredID
        ) == nil)

    let results = context.network.fetchedResults(for: query)
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    var transactions = controller.transactions.makeAsyncIterator()
    let topologyRevision = results.topologyRevision
    let membershipVisits = results.networkFullMembershipVisitCountForTesting
    var lookupCount = 0

    results.applyNetworkDelta(delta) { id in
        lookupCount += 1
        #expect(id == visibleID)
        return visibleRequest
    }

    #expect(try #require(await transactions.next()) == delta.transaction)
    #expect(results.items.first === visibleRequest)
    #expect(results.topologyRevision == topologyRevision)
    #expect(results.networkFullMembershipVisitCountForTesting == membershipVisits)
    #expect(lookupCount == 0)
}

@MainActor
@Test
func closedConsoleQueryPublishesOnlyVisibleContentUpdatesExactlyOnce() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let warning = Console.Level(rawValue: "warning")
    let log = Console.Level(rawValue: "log")
    let results = context.console.fetchedResults(
        for: ConsoleMessageQuery(
            filter: .level(warning),
            sectionBy: .level,
            fetchLimit: 2
        )
    )
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    var transactions = controller.transactions.makeAsyncIterator()
    let firstTarget = WebInspectorTarget.ID("closed-console-first")
    let filteredTarget = WebInspectorTarget.ID("closed-console-filtered")
    let secondTarget = WebInspectorTarget.ID("closed-console-second")

    context.apply(
        .messageAdded(Console.Message(source: .init(rawValue: "console-api"), level: warning, text: "first")),
        targetID: firstTarget
    )
    let firstID = try #require(results.items.first?.id)
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .insert(
                itemID: firstID,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])

    context.apply(
        .messageAdded(Console.Message(source: .init(rawValue: "console-api"), level: log, text: "filtered")),
        targetID: filteredTarget
    )
    context.apply(
        .messageAdded(Console.Message(source: .init(rawValue: "console-api"), level: warning, text: "second")),
        targetID: secondTarget
    )
    let secondID = try #require(results.items.last?.id)
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .insert(
                itemID: secondID,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])

    context.apply(.messageRepeatCountUpdated(count: 2, timestamp: 2), targetID: firstTarget)
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: firstID,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])

    context.apply(.messageRepeatCountUpdated(count: 3, timestamp: 3), targetID: filteredTarget)
    context.apply(.messageRepeatCountUpdated(count: 4, timestamp: 4), targetID: secondTarget)
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: secondID,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 1)
            )
        ])

    context.apply(.messageRepeatCountUpdated(count: 5, timestamp: 5), targetID: firstTarget)
    #expect(
        try #require(await transactions.next()).itemChanges == [
            .update(
                itemID: firstID,
                indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: 0)
            )
        ])
}

@MainActor
@Test
func maximumQueryWindowsCannotOverflowNetworkOrConsoleBounds() {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    for index in 0..<3 {
        context.seedNetworkRequest(
            requestID: "closed-window-\(index)",
            url: "https://example.test/\(index)",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: Double(index)
        )
        context.apply(
            .messageAdded(
                Console.Message(
                    source: Console.Source(rawValue: "console-api"),
                    level: Console.Level(rawValue: "log"),
                    text: "message-\(index)"
                )))
    }

    #expect(
        context.network.fetchedResults(
            for: NetworkRequestQuery(
                sortBy: [.requestSentTimestamp()],
                fetchLimit: .max,
                fetchOffset: 1
            )
        ).items.count == 2
    )
    #expect(
        context.network.fetchedResults(
            for: NetworkRequestQuery(
                sortBy: [.requestSentTimestamp()],
                fetchLimit: .max,
                fetchOffset: .max
            )
        ).items.isEmpty
    )
    #expect(
        context.console.fetchedResults(
            for: ConsoleMessageQuery(
                sortBy: [.text()],
                fetchLimit: .max,
                fetchOffset: 1
            )
        ).items.count == 2
    )
    #expect(
        context.console.fetchedResults(
            for: ConsoleMessageQuery(
                sortBy: [.text()],
                fetchLimit: .max,
                fetchOffset: .max
            )
        ).items.isEmpty
    )
}

@MainActor
@Test
func maximumNetworkWindowCannotOverflowTheRecordIndexPath() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    var inputs: [NetworkRequestRecordInput] = []
    for index in 0..<3 {
        let id = context.seedNetworkRequest(
            requestID: "closed-index-window-\(index)",
            url: "https://example.test/index/\(index)",
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: Double(index)
        )
        let request = try #require(context.registeredRequest(for: id))
        inputs.append(NetworkRequestRecordInput(request: request, orderIndex: index))
    }
    let index = NetworkRequestIndex()
    await index.replace(with: inputs, sequence: 1)
    let plan = NetworkRequestQueryPlan(
        query: NetworkRequestQuery(
            sortBy: [.requestSentTimestamp()],
            fetchLimit: .max,
            fetchOffset: 1
        ))

    let delta = try #require(
        await index.delta(
            plan: plan,
            sectionBy: nil,
            oldSnapshot: WebInspectorFetchedResultsSnapshot(),
            changedID: nil
        ))

    #expect(delta.snapshot.itemIDs.count == 2)
}

@MainActor
@Test
func updateQueryAppliesFilterSortSectionAndWindowAtomically() async throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    for (index, method) in ["GET", "POST", "GET"].enumerated() {
        context.seedNetworkRequest(
            requestID: "closed-update-\(index)",
            url: "https://example.test/\(index)",
            method: method,
            resourceTypeRawValue: "Fetch",
            responseMIMEType: "application/json",
            responseStatus: 200,
            responseStatusText: "OK",
            timestamp: Double(index)
        )
    }
    let results = context.network.fetchedResults()
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    var transactions = controller.transactions.makeAsyncIterator()
    let query = NetworkRequestQuery(
        filter: .method(equals: "GET"),
        sortBy: [.requestSentTimestamp(order: .reverse)],
        sectionBy: .method,
        fetchLimit: 1,
        fetchOffset: 0
    )

    try controller.updateQuery(query)

    let reset = try #require(await transactions.next())
    #expect(reset.isReset)
    #expect(reset.newSnapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "GET")])
    #expect(controller.query == query)
    #expect(controller.items.map(\.url) == ["https://example.test/2"])
    #expect(controller.snapshot.sectionIDs == [WebInspectorFetchSectionID(rawValue: "GET")])

    context.seedNetworkRequest(
        requestID: "closed-update-next",
        url: "https://example.test/next",
        method: "GET",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 4
    )
    let next = try #require(await transactions.next())
    #expect(next.isReset == false)
}

@MainActor
@Test
func queryOnlyUpdateInvalidatesObservedQueryWhenMembershipDoesNotChange() throws {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    context.seedNetworkRequest(
        requestID: "closed-query-observation",
        url: "https://example.test/observed",
        resourceTypeRawValue: "Fetch",
        responseMIMEType: "application/json",
        responseStatus: 200,
        responseStatusText: "OK",
        timestamp: 1
    )
    let results = context.network.fetchedResults()
    let changed = Mutex(false)
    withObservationTracking {
        _ = results.query
    } onChange: {
        changed.withLock { $0 = true }
    }
    let query = NetworkRequestQuery(fetchLimit: .max)

    try results.updateQuery(query)

    #expect(changed.withLock { $0 })
    #expect(results.query == query)
    #expect(results.items.count == 1)
}

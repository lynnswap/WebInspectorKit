import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
@Test
func networkNavigationGroupsEachAtoBtoAFrameVisitSeparately() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )
    let requests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )
    let entries = WebInspectorFetchedResultsController<NetworkEntry>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareOwnerContractNetworkAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await requests.performFetch()
            try await entries.performFetch()
            var requestUpdates = requests.updates.makeAsyncIterator()
            var entryUpdates = entries.updates.makeAsyncIterator()
            _ = await requestUpdates.next()
            _ = await entryUpdates.next()

            for (loaderID, prefix, timestamp) in [
                ("loader-a", "a-first", 1.0),
                ("loader-b", "b", 2.0),
                ("loader-a", "a-return", 3.0),
            ] {
                try await emitOwnerContractRequest(
                    id: "\(prefix)-provisional",
                    url: "https://example.test/\(prefix)-provisional",
                    frameID: "main-frame",
                    loaderID: loaderID,
                    nodeID: "42",
                    timestamp: timestamp,
                    through: runtime.wire
                )
                _ = await requestUpdates.next()
                _ = await entryUpdates.next()
                try await emitOwnerContractFrameNavigated(
                    frameID: "main-frame",
                    loaderID: loaderID,
                    through: runtime.wire
                )
                try await emitOwnerContractRequest(
                    id: "\(prefix)-committed",
                    url: "https://example.test/\(prefix)-committed",
                    frameID: "main-frame",
                    loaderID: loaderID,
                    nodeID: "42",
                    timestamp: timestamp + 0.5,
                    through: runtime.wire
                )
                _ = await requestUpdates.next()
                _ = await entryUpdates.next()
            }

            #expect(requests.fetchedObjects?.count == 6)
            #expect(entries.fetchedObjects?.map(\.requestIDs.count).sorted() == [2, 2, 2])

            await entries.close()
            await requests.close()
            await container.close()
        }
    } catch {
        await entries.close()
        await requests.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func networkBootstrapPreservesAtoBtoAVisitOwnership() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )
    let requests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )
    let entries = WebInspectorFetchedResultsController<NetworkEntry>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            await runtime.wire.respond(to: "Network.enable")
            await runtime.wire.respond(to: "Page.enable")
            let resourceTreeReply = await runtime.wire.deferReply(
                to: "Page.getResourceTree",
                with: try ownerContractResourceTree()
            )
            await runtime.wire.respond(to: "Page.disable")

            try await container.attach(owning: runtime.proxy)
            _ = await runtime.wire.observations.waitForCommands(
                method: "Page.getResourceTree",
                count: 1
            )

            for index in 0..<2 {
                try await emitOwnerContractRequest(
                    id: "a-first-\(index)",
                    url: "https://example.test/a-first-\(index)",
                    frameID: "main-frame",
                    loaderID: "loader-a",
                    nodeID: "42",
                    timestamp: Double(index),
                    through: runtime.wire
                )
            }
            try await emitOwnerContractFrameNavigated(
                frameID: "main-frame",
                loaderID: "loader-b",
                through: runtime.wire
            )
            try await emitOwnerContractRequest(
                id: "b-first",
                url: "https://example.test/b-first",
                frameID: "main-frame",
                loaderID: "loader-b",
                nodeID: "42",
                timestamp: 2,
                through: runtime.wire
            )

            resourceTreeReply.open()
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await requests.performFetch()
            try await entries.performFetch()
            var requestUpdates = requests.updates.makeAsyncIterator()
            var entryUpdates = entries.updates.makeAsyncIterator()
            _ = await requestUpdates.next()
            _ = await entryUpdates.next()

            try await emitOwnerContractRequest(
                id: "b-second",
                url: "https://example.test/b-second",
                frameID: "main-frame",
                loaderID: "loader-b",
                nodeID: "42",
                timestamp: 3,
                through: runtime.wire
            )
            _ = await requestUpdates.next()
            _ = await entryUpdates.next()
            try await emitOwnerContractFrameNavigated(
                frameID: "main-frame",
                loaderID: "loader-a",
                through: runtime.wire
            )
            for index in 0..<2 {
                try await emitOwnerContractRequest(
                    id: "a-return-\(index)",
                    url: "https://example.test/a-return-\(index)",
                    frameID: "main-frame",
                    loaderID: "loader-a",
                    nodeID: "42",
                    timestamp: Double(index + 4),
                    through: runtime.wire
                )
                _ = await requestUpdates.next()
                _ = await entryUpdates.next()
            }

            #expect(requests.fetchedObjects?.count == 6)
            #expect(entries.fetchedObjects?.map(\.requestIDs.count).sorted() == [2, 2, 2])

            await entries.close()
            await requests.close()
            await container.close()
        }
    } catch {
        await entries.close()
        await requests.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func frameDetachmentRetainsNetworkHistoryAndLateTerminalEvents() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )
    let requests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareOwnerContractNetworkAttachment(
                runtime,
                includesChildFrame: true
            )
            try await container.attach(owning: runtime.proxy)
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await requests.performFetch()
            var updates = requests.updates.makeAsyncIterator()
            _ = await updates.next()

            try await emitOwnerContractRequest(
                id: "detached-request",
                url: "https://example.test/detached",
                frameID: "child-frame",
                loaderID: "child-loader",
                protocolTargetID: "child-frame",
                nodeID: "42",
                timestamp: 1,
                through: runtime.wire
            )
            _ = await updates.next()

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Network.responseReceived",
                parameters: try testJSONObject(
                    """
                    {
                      "requestId":"detached-request",
                      "type":"Fetch",
                      "response":{
                        "url":"https://example.test/detached",
                        "status":200,
                        "statusText":"OK",
                        "headers":{},
                        "mimeType":"text/plain",
                        "source":"network"
                      },
                      "timestamp":1.5
                    }
                    """
                )
            )
            _ = await updates.next()

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Page.frameDetached",
                parameters: try testJSONObject(#"{"frameId":"child-frame"}"#)
            )
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Network.loadingFinished",
                parameters: try testJSONObject(
                    #"{"requestId":"detached-request","timestamp":2}"#
                )
            )
            _ = await updates.next()

            let retained = try #require(requests.fetchedObjects?.first)
            #expect(retained.url == "https://example.test/detached")
            #expect(retained.state == .finished)
            await runtime.wire.respond(
                to: "Network.getResponseBody",
                with: try testJSONObject(
                    #"{"body":"retained body","base64Encoded":false}"#
                )
            )
            let body = try await container.network.responseBody(for: retained.id)
            #expect(body.data == "retained body")

            await requests.close()
            await container.close()
        }
    } catch {
        await requests.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func networkBodyLocatorMaintenanceTouchesOnlyTheChangedRequest() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )
    let requests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareOwnerContractNetworkAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await requests.performFetch()
            var updates = requests.updates.makeAsyncIterator()
            _ = await updates.next()

            for index in 0..<64 {
                try await emitOwnerContractRequest(
                    id: "request-\(index)",
                    url: "https://example.test/\(index)",
                    frameID: "main-frame",
                    loaderID: "loader-a",
                    nodeID: "42",
                    timestamp: Double(index),
                    through: runtime.wire
                )
                _ = await updates.next()
            }
            await container.networkFeature
                .resetLiveLocatorRecordVisitCountForTesting()

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Network.dataReceived",
                parameters: try testJSONObject(
                    #"{"requestId":"request-63","dataLength":8,"encodedDataLength":4,"timestamp":65}"#
                )
            )
            _ = await updates.next()

            #expect(
                await container.networkFeature
                    .liveLocatorRecordVisitCountForTesting == 1
            )

            await requests.close()
            await container.close()
        }
    } catch {
        await requests.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func networkWaitsForTheDOMBindingCutBeforeReducingItsNextRequest() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )
    let initialNodes = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: container.mainContext
    )
    let liveRequests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareOwnerContractDOMAndNetworkAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            _ = try await waitForOwnerContractFeature(.dom, in: container)
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await initialNodes.performFetch()
            try await liveRequests.performFetch()
            var initialNodeUpdates = initialNodes.updates.makeAsyncIterator()
            var requestUpdates = liveRequests.updates.makeAsyncIterator()
            _ = await initialNodeUpdates.next()
            _ = await requestUpdates.next()
            let oldDocumentID = try #require(initialNodes.fetchedObjects?.first?.id)

            await runtime.wire.respond(
                to: "DOM.getDocument",
                with: try emptyDocumentResult(nodeID: "42")
            )
            let releaseDOM = DataKitRawWireGate()
            let didEnterDOMGate = DataKitRawWireGate()
            let holdDOM = Task {
                try await container.domFeature.withExclusiveStyleCommitForTesting {
                    didEnterDOMGate.open()
                    await releaseDOM.waiter.wait()
                }
            }
            await didEnterDOMGate.waiter.wait()

            let processedBefore = await container.networkFeature
                .requestStartProcessingCountForTesting
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.documentUpdated"
            )
            try await emitOwnerContractRequest(
                id: "after-document-cut",
                url: "https://example.test/after-document-cut",
                frameID: "main-frame",
                loaderID: "loader-a",
                nodeID: "42",
                timestamp: 1,
                through: runtime.wire
            )
            while await container.networkFeature
                .requestStartProcessingCountForTesting == processedBefore
            {
                await Task.yield()
            }

            releaseDOM.open()
            try await holdDOM.value
            _ = await requestUpdates.next()
            _ = try await waitForOwnerContractFeature(.dom, in: container)

            let currentNodes = WebInspectorFetchedResultsController<DOMNode>(
                modelContext: container.mainContext
            )
            let currentRequests = WebInspectorFetchedResultsController<NetworkRequest>(
                modelContext: container.mainContext
            )
            try await currentNodes.performFetch()
            try await currentRequests.performFetch()
            var currentNodeUpdates = currentNodes.updates.makeAsyncIterator()
            var currentRequestUpdates = currentRequests.updates.makeAsyncIterator()
            _ = await currentNodeUpdates.next()
            _ = await currentRequestUpdates.next()

            let newDocumentID = try #require(currentNodes.fetchedObjects?.first?.id)
            let initiatorID = try #require(
                currentRequests.fetchedQueryValues?.first?.initiatorNodeID
            )
            #expect(newDocumentID != oldDocumentID)
            #expect(initiatorID == newDocumentID)

            await currentRequests.close()
            await currentNodes.close()
            await liveRequests.close()
            await initialNodes.close()
            await container.close()
        }
    } catch {
        await liveRequests.close()
        await initialNodes.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func frameTargetDocumentCutDoesNotDeadlockNetworkReduction() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )
    let requests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareOwnerContractDOMAndNetworkAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            _ = try await waitForOwnerContractFeature(.dom, in: container)
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await requests.performFetch()
            var updates = requests.updates.makeAsyncIterator()
            _ = await updates.next()

            await runtime.wire.respond(to: "Network.enable")
            await runtime.wire.respond(to: "CSS.enable")
            await runtime.wire.respond(to: "Network.disable")
            await runtime.wire.respond(to: "CSS.disable")
            try await runtime.peer.createTarget(
                .init(
                    id: "frame-42-7",
                    type: "frame"
                )
            )
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "CSS.enable",
                count: 2
            )

            try await runtime.wire.emitTargetEvent(
                targetID: "frame-42-7",
                method: "DOM.documentUpdated"
            )
            try await emitOwnerContractRequest(
                id: "frame-request",
                url: "https://example.test/frame-request",
                frameID: "frame-7.42",
                loaderID: "child-loader",
                eventTargetID: "frame-42-7",
                nodeID: "42",
                timestamp: 1,
                through: runtime.wire
            )
            _ = await updates.next()

            #expect(requests.fetchedObjects?.map(\.url) == [
                "https://example.test/frame-request"
            ])

            await requests.close()
            await container.close()
        }
    } catch {
        await requests.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func unsupportedDOMReleasesNetworkBindingWaiters() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )
    let requests = WebInspectorFetchedResultsController<NetworkRequest>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            await runtime.wire.respond(to: "Page.enable")
            await runtime.wire.respond(to: "Network.enable")
            await runtime.wire.respond(to: "Inspector.enable")
            await runtime.wire.respond(to: "Inspector.initialized")
            await runtime.wire.respond(to: "CSS.enable")
            let documentFailure = await runtime.wire.deferFailure(
                to: "DOM.getDocument",
                code: -32_601,
                message: "'DOM.getDocument' was not found"
            )
            let resourceTreeReply = await runtime.wire.deferReply(
                to: "Page.getResourceTree",
                with: try ownerContractResourceTree()
            )
            await runtime.wire.respond(to: "Network.disable")
            await runtime.wire.respond(to: "CSS.disable")
            await runtime.wire.respond(to: "Inspector.disable")
            await runtime.wire.respond(to: "Page.disable")

            try await container.attach(owning: runtime.proxy)
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.getDocument",
                count: 1
            )
            _ = await runtime.wire.observations.waitForCommands(
                method: "Page.getResourceTree",
                count: 1
            )

            try await emitOwnerContractRequest(
                id: "without-dom",
                url: "https://example.test/without-dom",
                frameID: "main-frame",
                loaderID: "loader-a",
                nodeID: "42",
                timestamp: 1,
                through: runtime.wire
            )
            resourceTreeReply.open()
            while await container.networkFeature
                .requestStartProcessingCountForTesting == 0
            {
                await Task.yield()
            }

            documentFailure.open()
            let requirements = try await waitForOwnerContractUnsupportedFeature(
                .dom,
                in: container
            )
            #expect(requirements == ["DOM.getDocument"])
            _ = try await waitForOwnerContractFeature(.network, in: container)
            try await requests.performFetch()
            #expect(requests.fetchedObjects?.map(\.url) == [
                "https://example.test/without-dom"
            ])

            await requests.close()
            await container.close()
        }
    } catch {
        await requests.close()
        await container.close()
        throw error
    }
}

@MainActor
private func prepareOwnerContractNetworkAttachment(
    _ runtime: DataKitTestRuntime,
    includesChildFrame: Bool = false
) async throws {
    await runtime.wire.respond(to: "Network.enable")
    await runtime.wire.respond(to: "Page.enable")
    await runtime.wire.respond(
        to: "Page.getResourceTree",
        with: try ownerContractResourceTree(
            includesChildFrame: includesChildFrame
        )
    )
    await runtime.wire.respond(to: "Page.disable")
}

@MainActor
private func prepareOwnerContractDOMAndNetworkAttachment(
    _ runtime: DataKitTestRuntime
) async throws {
    await runtime.wire.respond(to: "Page.enable")
    await runtime.wire.respond(to: "Network.enable")
    await runtime.wire.respond(to: "Inspector.enable")
    await runtime.wire.respond(to: "Inspector.initialized")
    await runtime.wire.respond(to: "CSS.enable")
    await runtime.wire.respond(
        to: "DOM.getDocument",
        with: try emptyDocumentResult(nodeID: "42")
    )
    await runtime.wire.respond(
        to: "Page.getResourceTree",
        with: try ownerContractResourceTree()
    )
    await runtime.wire.respond(to: "CSS.disable")
    await runtime.wire.respond(to: "Inspector.disable")
    await runtime.wire.respond(to: "Page.disable")
}

@MainActor
private func waitForOwnerContractFeature(
    _ featureID: WebInspectorFeatureID,
    in container: WebInspectorModelContainer
) async throws -> WebInspectorPageGeneration {
    let current = container.featureState(for: featureID)
    if case let .ready(generation, _) = current { return generation }
    var states = container.featureStateUpdates(for: featureID).makeAsyncIterator()
    while let state = await states.next() {
        if case let .ready(generation, _) = state { return generation }
    }
    throw OwnerContractTestError.featureStateEnded
}

@MainActor
private func waitForOwnerContractUnsupportedFeature(
    _ featureID: WebInspectorFeatureID,
    in container: WebInspectorModelContainer
) async throws -> [String] {
    let current = container.featureState(for: featureID)
    if case let .unsupported(requirements) = current { return requirements }
    var states = container.featureStateUpdates(for: featureID).makeAsyncIterator()
    while let state = await states.next() {
        if case let .unsupported(requirements) = state { return requirements }
    }
    throw OwnerContractTestError.featureStateEnded
}

private func emitOwnerContractFrameNavigated(
    frameID: String,
    loaderID: String,
    through wire: DataKitRawWireDriver
) async throws {
    try await wire.emitTargetEvent(
        targetID: "page-main",
        method: "Page.frameNavigated",
        parameters: try testJSONObject(
            OwnerContractFrameNavigatedParameters(
                frame: .init(
                    id: frameID,
                    loaderId: loaderID,
                    name: "",
                    url: "https://example.test/",
                    mimeType: "text/html"
                )
            )
        )
    )
}

private func emitOwnerContractRequest(
    id: String,
    url: String,
    frameID: String,
    loaderID: String,
    eventTargetID: String = "page-main",
    protocolTargetID: String? = nil,
    nodeID: String,
    timestamp: Double,
    through wire: DataKitRawWireDriver
) async throws {
    try await wire.emitTargetEvent(
        targetID: eventTargetID,
        method: "Network.requestWillBeSent",
        parameters: try testJSONObject(
            OwnerContractRequestWillBeSentParameters(
                requestId: id,
                frameId: frameID,
                loaderId: loaderID,
                request: .init(url: url, method: "GET", headers: [:]),
                initiator: .init(type: "parser", nodeId: nodeID),
                type: Network.ResourceType.fetch.rawValue,
                timestamp: timestamp,
                targetId: protocolTargetID
            )
        )
    )
}

private func ownerContractResourceTree(
    includesChildFrame: Bool = false
) throws -> WebInspectorTestJSONObject {
    let child = includesChildFrame
        ? #"""
          ,"childFrames":[{
            "frame":{
              "id":"child-frame",
              "parentId":"main-frame",
              "loaderId":"child-loader",
              "name":"",
              "url":"",
              "mimeType":"text/html"
            },
            "resources":[]
          }]
          """#
        : ""
    return try testJSONObject(
        """
        {
          "frameTree":{
            "frame":{
              "id":"main-frame",
              "loaderId":"loader-a",
              "name":"",
              "url":"",
              "mimeType":"text/html"
            },
            "resources":[]\(child)
          }
        }
        """
    )
}

private struct OwnerContractFrameNavigatedParameters: Encodable {
    struct Frame: Encodable {
        let id: String
        let loaderId: String
        let name: String
        let url: String
        let mimeType: String
    }

    let frame: Frame
}

private struct OwnerContractRequestWillBeSentParameters: Encodable {
    struct Request: Encodable {
        let url: String
        let method: String
        let headers: [String: String]
    }

    struct Initiator: Encodable {
        let type: String
        let nodeId: String
    }

    let requestId: String
    let frameId: String
    let loaderId: String
    let request: Request
    let initiator: Initiator
    let type: String
    let timestamp: Double
    let targetId: String?
}

private enum OwnerContractTestError: Error {
    case featureStateEnded
}

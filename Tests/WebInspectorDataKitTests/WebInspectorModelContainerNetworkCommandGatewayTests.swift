import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

private enum NetworkBodyGatewayTestError: Error {
    case timedOut
}

private struct NetworkBodyGatewayRuntime {
    let container: WebInspectorModelContainer
    let runtime: WebInspectorProxyTestRuntime
    let wire: WebInspectorRawWireDriver

    static func start() async throws -> Self {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let wire = WebInspectorRawWireDriver(peer: runtime.peer)
        await wire.start()
        await wire.respond(to: "Page.enable")
        await wire.respond(to: "Network.enable")
        let container = WebInspectorModelContainer(
            configuration: .init(domains: [.network])
        )
        try await container.attach(owning: runtime.proxy)
        return Self(container: container, runtime: runtime, wire: wire)
    }

    func close() async {
        await wire.respond(to: "Network.disable")
        await wire.respond(to: "Page.disable")
        await container.close()
        await runtime.close()
        await wire.stop()
    }
}

private func withNetworkBodyGatewayRuntime<Output: Sendable>(
    _ operation: @escaping @Sendable (NetworkBodyGatewayRuntime) async throws -> Output
) async throws -> Output {
    let runtime = try await NetworkBodyGatewayRuntime.start()
    do {
        let output = try await operation(runtime)
        await runtime.close()
        return output
    } catch {
        await runtime.close()
        throw error
    }
}

@Test
func networkBodyGatewayRoutesThroughTheAllocatingPhysicalAgent() async throws {
    try await withNetworkBodyGatewayRuntime { fixture in
        await fixture.wire.respond(to: "Page.enable")
        await fixture.wire.respond(to: "Network.enable")
        try await fixture.runtime.peer.createTarget(
            .init(
                id: "frame-agent",
                type: "frame",
                frameID: "child-frame",
                parentFrameID: "main-frame"
            ))
        try await requireCanonicalTarget(
            WebInspectorTarget.ID("frame-agent"),
            in: fixture.container.core
        )
        let backend = Network.BackendResourceID(
            sourceProcessID: "network-process",
            resourceID: "resource-42"
        )
        let requestID = try await emitFinishedCanonicalRequest(
            rawID: "physical-route",
            targetID: "frame-agent",
            frameID: "child-frame",
            canonicalRawID: Network.Request.ID(
                "physical-route",
                scopedToTargetRawValue: "frame-agent"
            ),
            backendResourceIdentifier: backend,
            wire: fixture.wire,
            core: fixture.container.core
        )
        await fixture.wire.respond(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "physical", base64Encoded: false)
            )
        )

        let body = try await fixture.container.core.loadNetworkResponseBody(
            for: requestID
        )
        #expect(body.data == "physical")
        #expect(!body.base64Encoded)

        let commands = fixture.wire.observations.commands.filter {
            $0.method == "Network.getResponseBody"
        }
        let command = try #require(commands.first)
        #expect(commands.count == 1)
        #expect(command.destination == .target("frame-agent"))
        let parameters = try command.parameters.decode(
            NetworkBodyCommandParameters.self
        )
        #expect(parameters.requestId == "physical-route")
        #expect(
            parameters.backendResourceIdentifier
                == .init(
                    sourceProcessID: "network-process",
                    resourceID: "resource-42"
                ))
        let metrics = await fixture.container.core.metrics
        #expect(metrics.core.networkResponseBodyWireCommandCount == 1)
        #expect(metrics.networkResponseBodyOperationCount == 0)
    }
}

@Test
func networkBodyGatewayRejectsForeignMissingStaleAndIneligibleRequests()
    async throws
{
    try await withNetworkBodyGatewayRuntime { fixture in
        let rawID = Network.Request.ID("eligibility")
        try await fixture.wire.emitRaw(
            canonicalRequestWillBeSent(
                id: rawID.rawValue,
                url: "https://example.test/eligibility",
                originFrameID: "main-frame",
                timestamp: 1
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        let pendingID = try await requireCanonicalRequest(
            rawID: rawID,
            in: fixture.container.core
        ).id

        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.responseMissing
        ) {
            _ = try await fixture.container.core.loadNetworkResponseBody(
                for: pendingID
            )
        }

        try await fixture.wire.emitRaw(
            .responseReceived(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/eligibility",
                    status: 200,
                    mimeType: "text/plain"
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        _ = try await requireCanonicalRequest(
            rawID: rawID,
            lifecycle: .responded,
            in: fixture.container.core
        )
        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.responseNotFinished
        ) {
            _ = try await fixture.container.core.loadNetworkResponseBody(
                for: pendingID
            )
        }

        let missing = CanonicalNetworkRequestIDStorage(
            storeID: pendingID.storeID,
            attachmentGeneration: pendingID.attachmentGeneration,
            pageGeneration: pendingID.pageGeneration,
            agentTargetID: pendingID.agentTargetID,
            rawRequestID: Network.Request.ID("missing")
        )
        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.requestNotFound
        ) {
            _ = try await fixture.container.core.loadNetworkResponseBody(
                for: missing
            )
        }

        let stale = CanonicalNetworkRequestIDStorage(
            storeID: pendingID.storeID,
            attachmentGeneration: .init(
                rawValue: pendingID.attachmentGeneration.rawValue + 1
            ),
            pageGeneration: pendingID.pageGeneration,
            agentTargetID: pendingID.agentTargetID,
            rawRequestID: pendingID.rawRequestID
        )
        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.staleRequest
        ) {
            _ = try await fixture.container.core.loadNetworkResponseBody(
                for: stale
            )
        }

        let foreign = CanonicalNetworkRequestIDStorage(
            storeID: WebInspectorContainerStoreID(),
            attachmentGeneration: pendingID.attachmentGeneration,
            pageGeneration: pendingID.pageGeneration,
            agentTargetID: pendingID.agentTargetID,
            rawRequestID: pendingID.rawRequestID
        )
        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.foreignStore
        ) {
            _ = try await fixture.container.core.loadNetworkResponseBody(
                for: foreign
            )
        }

        let socketRawID = Network.Request.ID("socket")
        try await fixture.wire.emitRaw(
            .webSocket(
                .created(
                    id: socketRawID,
                    url: "wss://example.test/socket"
                )),
            target: WebInspectorTarget.ID("page-main")
        )
        try await fixture.wire.emitRaw(
            .webSocket(
                .handshakeRequest(
                    id: socketRawID,
                    request: Network.Request(
                        id: socketRawID,
                        url: "wss://example.test/socket",
                        method: "GET"
                    ),
                    timestamp: 3
                )),
            target: WebInspectorTarget.ID("page-main")
        )
        try await fixture.wire.emitRaw(
            .webSocket(
                .handshakeResponse(
                    id: socketRawID,
                    response: Network.Response(
                        url: "wss://example.test/socket",
                        status: 101
                    ),
                    timestamp: 4
                )),
            target: WebInspectorTarget.ID("page-main")
        )
        let socketID = try await requireCanonicalRequest(
            rawID: socketRawID,
            in: fixture.container.core
        ).id
        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError
                .webSocketIneligible
        ) {
            _ = try await fixture.container.core.loadNetworkResponseBody(
                for: socketID
            )
        }
        #expect(
            fixture.wire.observations.commands.contains {
                $0.method == "Network.getResponseBody"
            } == false)
    }
}

@Test
func networkBodyGatewayCoalescesCallersAndIsolatesWaiterCancellation()
    async throws
{
    try await withNetworkBodyGatewayRuntime { fixture in
        let requestID = try await emitFinishedCanonicalRequest(
            rawID: "coalesced",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "shared", base64Encoded: false)
            )
        )
        let core = fixture.container.core
        let first = Task.detached {
            try await core.loadNetworkResponseBody(for: requestID)
        }
        let second = Task.detached {
            try await core.loadNetworkResponseBody(for: requestID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Network.getResponseBody",
            count: 1
        )

        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(await core.metrics.networkResponseBodyOperationCount == 1)
        gate.open()
        let body = try await second.value
        #expect(body.data == "shared")
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "Network.getResponseBody"
            }.count == 1)
        let metrics = await core.metrics
        #expect(metrics.core.networkResponseBodyWireCommandCount == 1)
        #expect(metrics.core.networkResponseBodyCoalescedWaiterCount == 1)
        #expect(metrics.networkResponseBodyOperationCount == 0)
    }
}

@Test
func canonicalNetworkClearInvalidatesAnInFlightResponseBodyCommand() async throws {
    try await withNetworkBodyGatewayRuntime { fixture in
        let requestID = try await emitFinishedCanonicalRequest(
            rawID: "clear-in-flight",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "obsolete", base64Encoded: false)
            )
        )
        let core = fixture.container.core
        let operation = Task.detached {
            try await core.loadNetworkResponseBody(for: requestID)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Network.getResponseBody",
            count: 1
        )

        try await core.clearNetworkRequests()

        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.staleResponse
        ) {
            _ = try await operation.value
        }
        gate.open()
        for _ in 0..<1_000 {
            if await core.metrics.networkResponseBodyOperationCount == 0 {
                break
            }
            await Task.yield()
        }
        let metrics = await core.metrics
        #expect(metrics.networkResponseBodyOperationCount == 0)
        #expect(metrics.core.networkResponseBodyInvalidationCount == 1)
        let snapshot = await core.canonicalSnapshotForTesting()
        #expect(snapshot.network?.requests.isEmpty == true)
        #expect(snapshot.network?.entries.isEmpty == true)
    }
}

@Test
func networkBodyGatewayRejectsMultipartResponseRevisionRace() async throws {
    try await withNetworkBodyGatewayRuntime { fixture in
        let rawID = Network.Request.ID("multipart-race")
        let requestID = try await emitFinishedCanonicalRequest(
            rawID: rawID.rawValue,
            responseMIMEType: "multipart/x-mixed-replace",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let initial = try await requireCanonicalRequest(
            rawID: rawID,
            lifecycle: .finished,
            in: fixture.container.core
        )
        let gate = await fixture.wire.deferReply(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(
                Network.Body(data: "obsolete", base64Encoded: false)
            )
        )
        let operation = Task {
            try await fixture.container.core.loadNetworkResponseBody(
                for: requestID
            )
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Network.getResponseBody",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .responseReceived(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/multipart-race",
                    status: 200,
                    mimeType: "image/jpeg",
                    headers: ["X-Part": "2"]
                ),
                resourceType: .image,
                timestamp: 4
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        let replacement = try await requireCanonicalRequest(
            rawID: rawID,
            lifecycle: .finished,
            minimumResponseRevision: initial.responseBodyRevision + 1,
            in: fixture.container.core
        )
        #expect(replacement.responseBodyRevision > initial.responseBodyRevision)
        await #expect(
            throws: WebInspectorNetworkResponseBodyCommandError.staleResponse
        ) {
            _ = try await operation.value
        }
        gate.open()
        try await requireNetworkBodyGatewayOperationCount(
            0,
            in: fixture.container.core
        )
        let metrics = await fixture.container.core.metrics
        #expect(metrics.core.networkResponseBodyInvalidationCount == 1)
        #expect(metrics.networkResponseBodyOperationCount == 0)
    }
}

@Test
func networkBodyGatewayUsesTheCurrentHopAfterRedirect() async throws {
    try await withNetworkBodyGatewayRuntime { fixture in
        let rawID = Network.Request.ID("redirect")
        try await fixture.wire.emitRaw(
            canonicalRequestWillBeSent(
                id: rawID.rawValue,
                url: "https://example.test/start",
                backendResourceIdentifier: .init(
                    sourceProcessID: "process",
                    resourceID: "start-resource"
                ),
                originFrameID: "main-frame",
                timestamp: 1
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        try await fixture.wire.emitRaw(
            .responseReceived(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/start",
                    status: 302,
                    headers: ["Location": "https://example.test/final"]
                ),
                resourceType: .fetch,
                timestamp: 2
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        try await fixture.wire.emitRaw(
            canonicalRequestWillBeSent(
                id: rawID.rawValue,
                url: "https://example.test/final",
                backendResourceIdentifier: .init(
                    sourceProcessID: "process",
                    resourceID: "final-resource"
                ),
                resourceType: .fetch,
                redirectResponse: Network.Response(
                    url: "https://example.test/start",
                    status: 302,
                    headers: ["Location": "https://example.test/final"]
                ),
                originFrameID: "main-frame",
                timestamp: 3
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        try await fixture.wire.emitRaw(
            .responseReceived(
                id: rawID,
                response: Network.Response(
                    url: "https://example.test/final",
                    status: 200,
                    mimeType: "text/plain"
                ),
                resourceType: .fetch,
                timestamp: 4
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        try await fixture.wire.emitRaw(
            .loadingFinished(
                id: rawID,
                timestamp: 5,
                sourceMapURL: nil,
                metrics: nil
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        let record = try await requireCanonicalRequest(
            rawID: rawID,
            lifecycle: .finished,
            in: fixture.container.core
        )
        #expect(record.redirects.count == 1)
        await fixture.wire.respond(
            to: "Network.getResponseBody",
            with: try rawNetworkBodyResult(Network.Body(data: "final"))
        )

        _ = try await fixture.container.core.loadNetworkResponseBody(
            for: record.id
        )
        let command = try #require(
            fixture.wire.observations.commands.last(where: {
                $0.method == "Network.getResponseBody"
            })
        )
        let parameters = try command.parameters.decode(
            NetworkBodyCommandParameters.self
        )
        #expect(parameters.requestId == rawID.rawValue)
        #expect(
            parameters.backendResourceIdentifier?.resourceID
                == "final-resource")
    }
}

@Test
func networkBodyGatewayDetachRejectsOldLeaseAndAllowsReattachment()
    async throws
{
    let first = try await NetworkBodyGatewayRuntime.start()
    let requestID = try await emitFinishedCanonicalRequest(
        rawID: "reattach",
        wire: first.wire,
        core: first.container.core
    )
    let gate = await first.wire.deferReply(
        to: "Network.getResponseBody",
        with: try rawNetworkBodyResult(Network.Body(data: "old"))
    )
    let operation = Task {
        try await first.container.core.loadNetworkResponseBody(for: requestID)
    }
    _ = await first.wire.observations.waitForCommands(
        method: "Network.getResponseBody",
        count: 1
    )
    await first.wire.respond(to: "Network.disable")
    await first.wire.respond(to: "Page.disable")
    let detach = Task { await first.container.detach() }
    await #expect(
        throws: WebInspectorNetworkResponseBodyCommandError.detached
    ) {
        _ = try await operation.value
    }
    await detach.value
    gate.open()
    #expect(first.container.state == .detached)
    #expect(
        await first.container.core.metrics.networkResponseBodyOperationCount
            == 0)
    await first.runtime.close()
    await first.wire.stop()

    let secondRuntime = try await WebInspectorProxyTestRuntime.start()
    let secondWire = WebInspectorRawWireDriver(peer: secondRuntime.peer)
    await secondWire.start()
    await secondWire.respond(to: "Page.enable")
    await secondWire.respond(to: "Network.enable")
    try await first.container.attach(owning: secondRuntime.proxy)
    let replacementID = try await emitFinishedCanonicalRequest(
        rawID: "reattach",
        wire: secondWire,
        core: first.container.core
    )
    #expect(replacementID != requestID)
    await #expect(
        throws: WebInspectorNetworkResponseBodyCommandError.staleRequest
    ) {
        _ = try await first.container.core.loadNetworkResponseBody(for: requestID)
    }
    await secondWire.respond(
        to: "Network.getResponseBody",
        with: try rawNetworkBodyResult(Network.Body(data: "new"))
    )
    let replacementBody = try await first.container.core
        .loadNetworkResponseBody(for: replacementID)
    #expect(replacementBody.data == "new")

    await secondWire.respond(to: "Network.disable")
    await secondWire.respond(to: "Page.disable")
    await first.container.close()
    await secondRuntime.close()
    await secondWire.stop()
}

@Test
func networkBodyGatewayCloseSettlesWaitersAndDrainsOwnedWireTask()
    async throws
{
    let fixture = try await NetworkBodyGatewayRuntime.start()
    let requestID = try await emitFinishedCanonicalRequest(
        rawID: "close",
        wire: fixture.wire,
        core: fixture.container.core
    )
    let gate = await fixture.wire.deferReply(
        to: "Network.getResponseBody",
        with: try rawNetworkBodyResult(Network.Body(data: "late"))
    )
    let operation = Task {
        try await fixture.container.core.loadNetworkResponseBody(for: requestID)
    }
    _ = await fixture.wire.observations.waitForCommands(
        method: "Network.getResponseBody",
        count: 1
    )
    await fixture.wire.respond(to: "Network.disable")
    await fixture.wire.respond(to: "Page.disable")
    let close = Task { await fixture.container.close() }
    await #expect(
        throws: WebInspectorNetworkResponseBodyCommandError.closed
    ) {
        _ = try await operation.value
    }
    await close.value
    #expect(fixture.container.state == .closed)
    #expect(
        await fixture.container.core.metrics.networkResponseBodyOperationCount
            == 0)
    gate.open()
    await fixture.runtime.close()
    await fixture.wire.stop()
}

private func emitFinishedCanonicalRequest(
    rawID: String,
    targetID: String = "page-main",
    frameID: String = "main-frame",
    canonicalRawID: Network.Request.ID? = nil,
    backendResourceIdentifier: Network.BackendResourceID? = nil,
    responseMIMEType: String = "text/plain",
    wire: WebInspectorRawWireDriver,
    core: WebInspectorModelContainerCore
) async throws -> CanonicalNetworkRequestIDStorage {
    let id = Network.Request.ID(rawID)
    try await wire.emitRaw(
        canonicalRequestWillBeSent(
            id: rawID,
            url: "https://example.test/\(rawID)",
            backendResourceIdentifier: backendResourceIdentifier,
            originFrameID: frameID,
            timestamp: 1
        ),
        target: WebInspectorTarget.ID(targetID)
    )
    try await wire.emitRaw(
        .responseReceived(
            id: id,
            response: Network.Response(
                url: "https://example.test/\(rawID)",
                status: 200,
                mimeType: responseMIMEType
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: WebInspectorTarget.ID(targetID)
    )
    try await wire.emitRaw(
        .loadingFinished(
            id: id,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: nil
        ),
        target: WebInspectorTarget.ID(targetID)
    )
    return try await requireCanonicalRequest(
        rawID: canonicalRawID ?? id,
        lifecycle: .finished,
        in: core
    ).id
}

private func requireCanonicalRequest(
    rawID: Network.Request.ID,
    lifecycle: CanonicalNetworkLifecycle? = nil,
    minimumResponseRevision: UInt64? = nil,
    in core: WebInspectorModelContainerCore
) async throws -> CanonicalNetworkRequestRecord {
    for _ in 0..<10_000 {
        let record = await core.canonicalSnapshotForTesting().network?
            .requests
            .lazy
            .map(\.record)
            .first(where: { $0.id.rawRequestID == rawID })
        if let record,
            lifecycle.map({ record.lifecycle == $0 }) ?? true,
            minimumResponseRevision.map({
                record.responseBodyRevision >= $0
            }) ?? true
        {
            return record
        }
        await Task.yield()
    }
    throw NetworkBodyGatewayTestError.timedOut
}

private func requireCanonicalTarget(
    _ targetID: WebInspectorTarget.ID,
    in core: WebInspectorModelContainerCore
) async throws {
    for _ in 0..<10_000 {
        if await core.canonicalSnapshotForTesting().binding?
            .targets
            .contains(where: { $0.target.id == targetID }) == true
        {
            return
        }
        await Task.yield()
    }
    throw NetworkBodyGatewayTestError.timedOut
}

private func requireNetworkBodyGatewayOperationCount(
    _ expectedCount: Int,
    in core: WebInspectorModelContainerCore
) async throws {
    for _ in 0..<10_000 {
        if await core.metrics.networkResponseBodyOperationCount == expectedCount {
            return
        }
        await Task.yield()
    }
    throw NetworkBodyGatewayTestError.timedOut
}

private struct NetworkBodyCommandParameters: Decodable {
    struct BackendResourceIdentifier: Decodable, Equatable {
        let sourceProcessID: String
        let resourceID: String
    }

    let requestId: String
    let backendResourceIdentifier: BackendResourceIdentifier?
}

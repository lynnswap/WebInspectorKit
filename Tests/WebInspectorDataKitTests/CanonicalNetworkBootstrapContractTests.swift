import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private struct NetworkBootstrapFixture {
    let storeID: WebInspectorContainerStoreID
    let attachmentGeneration = WebInspectorAttachmentGeneration(rawValue: 1)
    let pageGeneration = WebInspectorPageGeneration(rawValue: 1)
    var store: CanonicalNetworkStore

    init() throws {
        let storeID = WebInspectorContainerStoreID()
        self.storeID = storeID
        store = CanonicalNetworkStore(storeID: storeID)
        _ = try store.reset(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration
        )
    }

    func scope(
        semanticTargetID: String = "page",
        agentTargetID: String = "page",
        frameID: String? = nil,
        loaderID: String? = nil,
        domBindingEpoch: UInt64? = nil
    ) -> WebInspectorCanonicalNetworkEventScope {
        let semanticID = WebInspectorTarget.ID(semanticTargetID)
        let agentID = WebInspectorTarget.ID(agentTargetID)
        let modelScope = WebInspectorFeatureEventScope(
            generation: pageGeneration,
            semanticTarget: WebInspectorFeatureTarget(
                id: semanticID,
                kind: .page,
                frameID: frameID.map(FrameID.init)
            ),
            agentTarget: WebInspectorFeatureTarget(
                id: agentID,
                kind: .page,
                frameID: nil
            )
        )
        let origin: CanonicalNetworkRequestOrigin =
            frameID.map {
                .mappedFrame(frameID: FrameID($0), targetID: semanticID)
            } ?? .eventTarget(semanticID)
        return WebInspectorCanonicalNetworkEventScope(
            modelScope: modelScope,
            membership: CanonicalNetworkRequestMembership(
                pageGeneration: pageGeneration,
                agentTargetID: agentID,
                origin: origin,
                targetAuthority: CanonicalNetworkRegisteredTargetAuthority(
                    targetID: semanticID,
                    navigationEpoch: WebInspectorNavigationEpoch(rawValue: 0),
                    domBindingEpoch: domBindingEpoch.map {
                        WebInspectorDOMBindingScopeID(rawValue: $0)
                    }
                ),
                frameID: frameID.map(FrameID.init),
                loaderID: loaderID
            )
        )
    }
}

private func bootstrapRequest(
    id: String,
    url: String,
    method: String = "GET",
    nodeID: String? = nil,
    redirectResponse: Network.Response? = nil,
    timestamp: Double
) -> Network.Event {
    let rawID = Network.Request.ID(id)
    return .requestWillBeSent(
        id: rawID,
        request: Network.Request(
            id: rawID,
            url: url,
            method: method
        ),
        initiator: Network.Initiator(
            kind: nodeID == nil ? "other" : "parser",
            nodeID: nodeID.map(DOM.Node.ID.init)
        ),
        resourceType: .media,
        redirectResponse: redirectResponse,
        timestamp: timestamp
    )
}

private func snapshotResource(
    frameID: String,
    loaderID: String?,
    url: String,
    type: Network.ResourceType = .media,
    mimeType: String = "video/mp4"
) -> CanonicalNetworkSnapshotResource {
    CanonicalNetworkSnapshotResource(
        frameID: FrameID(frameID),
        loaderID: loaderID,
        url: url,
        type: type,
        mimeType: mimeType,
        failed: false,
        canceled: false,
        sourceMapURL: nil
    )
}

@Test
func canonicalNetworkBootstrapMatchesExactLoaderIdentity() throws {
    var fixture = try NetworkBootstrapFixture()
    let scope = fixture.scope(frameID: "main", loaderID: "loader-a")
    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "live",
            url: "https://example.test/movie.mp4",
            timestamp: 1
        ),
        scope: scope
    )
    let liveID = try #require(fixture.store.requests.first?.id)

    let result = try fixture.store.reconcileSnapshotResource(
        snapshotResource(
            frameID: "main",
            loaderID: "loader-a",
            url: "https://example.test/movie.mp4"
        ),
        scope: scope
    )

    #expect(result.requestID == liveID)
    #expect(fixture.store.requests.count == 1)
    #expect(fixture.store.request(for: liveID)?.lifecycle == .pending)

    _ = try fixture.store.reduce(
        .loadingFinished(
            id: Network.Request.ID("live"),
            timestamp: 2,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: scope
    )
    #expect(fixture.store.request(for: liveID)?.lifecycle == .finished)
}

@Test
func canonicalNetworkBootstrapMatchesUniqueLoaderUnknownAlias() throws {
    var fixture = try NetworkBootstrapFixture()
    let liveScope = fixture.scope(
        frameID: "main",
        loaderID: "loader-a"
    )
    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "live",
            url: "https://example.test/movie.mp4",
            timestamp: 1
        ),
        scope: liveScope
    )
    let liveID = try #require(fixture.store.requests.first?.id)
    let loaderUnknownScope = fixture.scope(frameID: "main")

    let snapshot = try fixture.store.reconcileSnapshotResource(
        snapshotResource(
            frameID: "main",
            loaderID: nil,
            url: "https://example.test/movie.mp4"
        ),
        scope: loaderUnknownScope
    )

    #expect(fixture.store.requests.count == 1)
    #expect(snapshot.requestID == liveID)
}

@Test
func canonicalNetworkBootstrapKeepsAmbiguousURLAsSeparateIdentity() throws {
    var fixture = try NetworkBootstrapFixture()
    let url = "https://example.test/shared.mp4"
    for (frameID, loaderID) in [("frame-a", "loader-a"), ("frame-b", "loader-b")] {
        _ = try fixture.store.reconcileSnapshotResource(
            snapshotResource(
                frameID: frameID,
                loaderID: loaderID,
                url: url
            ),
            scope: fixture.scope(frameID: frameID, loaderID: loaderID)
        )
    }
    let missingOriginScope = fixture.scope()
    _ = try fixture.store.reduce(
        bootstrapRequest(id: "live", url: url, timestamp: 1),
        scope: missingOriginScope
    )

    #expect(fixture.store.requests.count == 3)
    let liveID = try #require(
        fixture.store.requestID(
            forRawRequestID: Network.Request.ID("live"),
            scope: missingOriginScope
        )
    )
    #expect(fixture.store.requests.filter { $0.id == liveID }.count == 1)
}

@Test
func canonicalNetworkSnapshotNeverCrossesAgentAuthority() throws {
    var fixture = try NetworkBootstrapFixture()
    let url = "https://example.test/movie.mp4"
    let snapshot = try fixture.store.reconcileSnapshotResource(
        snapshotResource(
            frameID: "main",
            loaderID: "loader-a",
            url: url
        ),
        scope: fixture.scope(
            agentTargetID: "agent-a",
            frameID: "main",
            loaderID: "loader-a"
        )
    )
    let liveScope = fixture.scope(
        agentTargetID: "agent-b",
        frameID: "main",
        loaderID: "loader-a"
    )

    _ = try fixture.store.reduce(
        bootstrapRequest(id: "live", url: url, timestamp: 1),
        scope: liveScope
    )

    let liveID = try #require(
        fixture.store.requestID(
            forRawRequestID: Network.Request.ID("live"),
            scope: liveScope
        )
    )
    #expect(fixture.store.requests.count == 2)
    #expect(liveID != snapshot.requestID)
}

@Test
func canonicalNetworkResponseFirstCompletesWithLaterRequest() throws {
    var fixture = try NetworkBootstrapFixture()
    let scope = fixture.scope()
    let rawID = Network.Request.ID("response-first")
    _ = try fixture.store.reduce(
        .responseReceived(
            id: rawID,
            response: Network.Response(
                url: "https://example.test/api",
                status: 200,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 2
        ),
        scope: scope
    )
    let responseFirstID = try #require(fixture.store.requests.first?.id)

    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "response-first",
            url: "https://example.test/api",
            method: "POST",
            timestamp: 1
        ),
        scope: scope
    )

    let request = try #require(fixture.store.requests.first)
    #expect(request.id == responseFirstID)
    #expect(request.requestProvenance == .authoritativeRequest)
    #expect(request.currentHop.request.method == "POST")
    #expect(request.currentHop.response?.status == 200)
}

@Test
func canonicalNetworkSnapshotLearnsLiveAliasWithoutChangingID() throws {
    var fixture = try NetworkBootstrapFixture()
    let snapshotScope = fixture.scope(
        frameID: "main",
        loaderID: "loader-a"
    )
    let snapshot = try fixture.store.reconcileSnapshotResource(
        snapshotResource(
            frameID: "main",
            loaderID: "loader-a",
            url: "https://example.test/movie.mp4"
        ),
        scope: snapshotScope
    )
    let liveScope = fixture.scope()

    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "raw-live",
            url: "https://example.test/movie.mp4",
            timestamp: 1
        ),
        scope: liveScope
    )

    #expect(fixture.store.requests.map(\.id) == [snapshot.requestID])
    #expect(
        fixture.store.rawRequestAlias(for: snapshot.requestID)?.rawRequestID
            == Network.Request.ID("raw-live")
    )

    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "raw-next",
            url: "https://example.test/movie.mp4",
            timestamp: 2
        ),
        scope: liveScope
    )
    #expect(fixture.store.requests.count == 2)
}

@Test
func canonicalNetworkGapRecoveryRetainsBaselineAndPublishesAtomically() throws {
    var fixture = try NetworkBootstrapFixture()
    let scope = fixture.scope()
    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "http",
            url: "https://example.test/data.json",
            timestamp: 1
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: Network.Request.ID("http"),
            timestamp: 2,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: scope
    )
    let socketRawID = Network.Request.ID("socket")
    _ = try fixture.store.reduce(
        .webSocket(.created(id: socketRawID, url: "wss://example.test/socket")),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .handshakeRequest(
                id: socketRawID,
                request: Network.Request(
                    id: socketRawID,
                    url: "wss://example.test/socket",
                    method: "GET"
                ),
                timestamp: 3
            )
        ),
        scope: scope
    )
    let httpID = try #require(
        fixture.store.requestID(
            forRawRequestID: Network.Request.ID("http"),
            scope: scope
        )
    )
    let socketID = try #require(
        fixture.store.requestID(forRawRequestID: socketRawID, scope: scope)
    )
    let publishedLastSuccess = fixture.store
    var staged = publishedLastSuccess

    try staged.prepareBootstrap(
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: fixture.pageGeneration
    )
    _ = try staged.reduce(
        bootstrapRequest(
            id: "during-recovery",
            url: "https://example.test/recovered.json",
            timestamp: 4
        ),
        scope: scope
    )

    #expect(publishedLastSuccess.requests.count == 2)
    #expect(publishedLastSuccess.request(for: httpID) != nil)
    #expect(
        publishedLastSuccess.request(for: socketID)?.webSocket?.continuity
            == .continuous
    )
    #expect(staged.requests.count == 3)
    #expect(staged.request(for: httpID) != nil)
    #expect(
        staged.request(for: socketID)?.webSocket?.continuity
            == .unknownAfterGap
    )
    #expect(staged.requests.filter { $0.id == socketID }.count == 1)
}

@Test
func canonicalNetworkInitialPreviewUsesOldestSuccessfulPlayableFinalHop() throws {
    var fixture = try NetworkBootstrapFixture()
    let scope = fixture.scope(domBindingEpoch: 1)

    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "newer",
            url: "https://example.test/newer.mp4",
            nodeID: "media-node",
            timestamp: 20
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("newer"),
            response: Network.Response(
                url: "https://example.test/newer.mp4",
                status: 200,
                mimeType: "video/mp4"
            ),
            resourceType: .media,
            timestamp: 21
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: Network.Request.ID("newer"),
            timestamp: 22,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: scope
    )

    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "older",
            url: "https://example.test/start.txt",
            nodeID: "media-node",
            timestamp: 10
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        bootstrapRequest(
            id: "older",
            url: "https://example.test/older.mp4",
            nodeID: "media-node",
            redirectResponse: Network.Response(
                url: "https://example.test/start.txt",
                status: 302
            ),
            timestamp: 11
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("older"),
            response: Network.Response(
                url: "https://example.test/older.mp4",
                status: 200,
                mimeType: "video/mp4"
            ),
            resourceType: .media,
            timestamp: 12
        ),
        scope: scope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: Network.Request.ID("older"),
            timestamp: 13,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: scope
    )

    let olderID = try #require(
        fixture.store.requestID(
            forRawRequestID: Network.Request.ID("older"),
            scope: scope
        )
    )
    let entry = try #require(fixture.store.entries.first)
    #expect(fixture.store.entries.count == 1)
    #expect(entry.requestIDs.first == olderID)
    #expect(entry.summary.initialMediaPreviewRequestID == olderID)
    #expect(
        fixture.store.request(for: olderID)?.currentHop.request.url
            == "https://example.test/older.mp4"
    )
}

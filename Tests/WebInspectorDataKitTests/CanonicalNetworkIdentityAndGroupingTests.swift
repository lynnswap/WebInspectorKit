import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func canonicalNetworkIdentityScopesCannotAlias() throws {
    let firstStoreUUID = UUID(
        uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 1
        ))
    let secondStoreUUID = UUID(
        uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 2
        ))
    var fixture = try CanonicalNetworkTestFixture(
        storeUUID: firstStoreUUID
    )
    let targetA = fixture.scope(targetID: "target-a")
    let targetB = fixture.scope(targetID: "target-b")
    let rawID = Network.Request.ID("request\u{1e}with-separator")
    let targetAStorage = CanonicalNetworkRequestIDStorage(
        storeID: fixture.storeID,
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: fixture.pageGeneration,
        agentTargetID: WebInspectorTarget.ID("target-a"),
        rawRequestID: rawID
    )
    let targetBStorage = CanonicalNetworkRequestIDStorage(
        storeID: fixture.storeID,
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: fixture.pageGeneration,
        agentTargetID: WebInspectorTarget.ID("target-b"),
        rawRequestID: rawID
    )
    #expect(targetAStorage != targetBStorage)

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request\u{1e}with-separator",
            url: "https://example.test/a",
            timestamp: 1
        ),
        scope: targetA
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "different-request",
            url: "https://example.test/b",
            timestamp: 2
        ),
        scope: targetB
    )

    let targetScopedIDs = fixture.store.requests.map(\.id)
    #expect(Set(targetScopedIDs).count == 2)
    #expect(
        targetScopedIDs.map(\.rawRequestID) == [
            Network.Request.ID("request\u{1e}with-separator"),
            Network.Request.ID("different-request"),
        ])

    var otherStore = try CanonicalNetworkTestFixture(
        storeUUID: secondStoreUUID
    )
    _ = try otherStore.store.reduce(
        canonicalRequestWillBeSent(
            id: "request\u{1e}with-separator",
            url: "https://example.test/a",
            timestamp: 1
        ),
        scope: otherStore.scope(targetID: "target-a")
    )
    #expect(otherStore.store.requests[0].id != targetScopedIDs[0])

    let oldID = targetScopedIDs[0]
    _ = try fixture.store.reset(
        attachmentGeneration: .init(rawValue: 2),
        pageGeneration: .init(rawValue: 1)
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request\u{1e}with-separator",
            url: "https://example.test/attachment-2",
            timestamp: 3
        ),
        scope: fixture.scope(
            targetID: "target-a",
            pageGeneration: .init(rawValue: 1)
        )
    )
    let attachmentScopedID = fixture.store.requests[0].id
    #expect(attachmentScopedID != oldID)
    #expect(attachmentScopedID.attachmentGeneration == .init(rawValue: 2))

    _ = try fixture.store.reset(
        attachmentGeneration: .init(rawValue: 2),
        pageGeneration: .init(rawValue: 2)
    )
    let pageTwoScope = fixture.scope(
        targetID: "target-a",
        pageGeneration: .init(rawValue: 2)
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "request\u{1e}with-separator",
            url: "https://example.test/page-2",
            timestamp: 4
        ),
        scope: pageTwoScope
    )
    let pageScopedID = fixture.store.requests[0].id
    #expect(pageScopedID != attachmentScopedID)
    #expect(pageScopedID.pageGeneration == .init(rawValue: 2))
}

@Test
func canonicalNetworkRawRequestLookupRejectsLiveAgentCollisions() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let rawID = Network.Request.ID("console-reference")
    let firstScope = fixture.scope(
        targetID: "worker-a",
        agentTargetID: "agent-a"
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "console-reference",
            url: "https://example.test/a.js",
            timestamp: 1
        ),
        scope: firstScope
    )
    let existingID = try #require(
        fixture.store.requestID(forRawRequestID: rawID)
    )
    #expect(fixture.store.request(for: existingID) != nil)

    let secondScope = fixture.scope(
        targetID: "worker-b",
        agentTargetID: "agent-b"
    )
    let proposedID = CanonicalNetworkRequestIDStorage(
        storeID: fixture.storeID,
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: fixture.pageGeneration,
        agentTargetID: WebInspectorTarget.ID("agent-b"),
        rawRequestID: rawID
    )
    let beforeCollision = fixture.store
    #expect(
        throws:
            CanonicalNetworkProtocolViolation
            .rawRequestIdentifierCollision(
                rawID: rawID,
                existingID: existingID,
                proposedID: proposedID
            )
    ) {
        try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: "console-reference",
                url: "https://example.test/b.js",
                timestamp: 2
            ),
            scope: secondScope
        )
    }
    #expect(fixture.store == beforeCollision)

    _ = try fixture.store.targetWasLost(
        WebInspectorTarget.ID("agent-a")
    )
    #expect(fixture.store.requestID(forRawRequestID: rawID) == nil)
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "console-reference",
            url: "https://example.test/b.js",
            timestamp: 3
        ),
        scope: secondScope
    )
    #expect(fixture.store.requestID(forRawRequestID: rawID) == proposedID)
}

@Test
func canonicalNetworkInitiatorKeysSeparateSemanticAndAgentTargets() {
    let storeID = WebInspectorContainerStoreID(
        rawValue: UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 1
            )))
    let attachmentGeneration = WebInspectorContainerAttachmentGeneration(
        rawValue: 1
    )
    let pageGeneration = WebInspectorPage.Generation(rawValue: 1)
    let semanticTargetID = WebInspectorTarget.ID("frame")
    let firstAgentTargetID = WebInspectorTarget.ID("agent-a")
    let secondAgentTargetID = WebInspectorTarget.ID("agent-b")

    let firstDOMKey = WebInspectorDOMNodeIdentityStorage(
        documentScope: WebInspectorDOMDocumentScopeStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration,
            semanticTargetID: semanticTargetID,
            agentTargetID: firstAgentTargetID,
            domBindingEpoch: .init(rawValue: 1)
        ),
        rawNodeID: DOM.Node.ID("node")
    )
    let secondDOMKey = WebInspectorDOMNodeIdentityStorage(
        documentScope: WebInspectorDOMDocumentScopeStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration,
            semanticTargetID: semanticTargetID,
            agentTargetID: secondAgentTargetID,
            domBindingEpoch: .init(rawValue: 1)
        ),
        rawNodeID: DOM.Node.ID("node")
    )
    #expect(firstDOMKey != secondDOMKey)

    let firstOpaqueKey = CanonicalNetworkOpaqueInitiatorKey(
        storeID: storeID,
        attachmentGeneration: attachmentGeneration,
        pageGeneration: pageGeneration,
        semanticTargetID: semanticTargetID,
        agentTargetID: firstAgentTargetID,
        navigationEpoch: .init(rawValue: 1),
        rawNodeID: DOM.Node.ID("node")
    )
    let secondOpaqueKey = CanonicalNetworkOpaqueInitiatorKey(
        storeID: storeID,
        attachmentGeneration: attachmentGeneration,
        pageGeneration: pageGeneration,
        semanticTargetID: semanticTargetID,
        agentTargetID: secondAgentTargetID,
        navigationEpoch: .init(rawValue: 1),
        rawNodeID: DOM.Node.ID("node")
    )
    #expect(firstOpaqueKey != secondOpaqueKey)
}

@Test
func canonicalNetworkChronologyOrdersMissingTimestampsFirst() {
    let firstMissing = CanonicalNetworkChronologyKey(
        timestamp: nil,
        insertionOrdinal: 1
    )
    let secondMissing = CanonicalNetworkChronologyKey(
        timestamp: nil,
        insertionOrdinal: 2
    )
    let timestamped = CanonicalNetworkChronologyKey(
        timestamp: 0,
        insertionOrdinal: 3
    )

    #expect(firstMissing < secondMissing)
    #expect(secondMissing < timestamped)
    #expect(!(timestamped < firstMissing))
}

@Test
func canonicalNetworkGroupingSeparatesAgentsAndKeepsInitialSemanticMembership() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let firstAgentScope = fixture.scope(
        targetID: "worker",
        agentTargetID: "agent-a",
        domBindingEpoch: 1
    )
    let secondAgentScope = fixture.scope(
        targetID: "worker",
        agentTargetID: "agent-b",
        domBindingEpoch: 1
    )
    for (scope, rawID) in [
        (firstAgentScope, "agent-a-request"),
        (secondAgentScope, "agent-b-request"),
    ] {
        _ = try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: rawID,
                url: "https://example.test/worker.js",
                initiatorNodeID: "shared-node",
                timestamp: 1
            ),
            scope: scope
        )
    }

    #expect(fixture.store.requests.count == 2)
    #expect(fixture.store.entries.count == 2)
    let firstAgentRequest = try #require(
        fixture.store.requests.first {
            $0.id.agentTargetID == WebInspectorTarget.ID("agent-a")
        }
    )
    let firstAgentEntry = try #require(
        fixture.store.entry(containing: firstAgentRequest.id)
    )
    guard case let .dom(initialGroupKey) = firstAgentEntry.groupKey else {
        Issue.record("Expected a DOM-backed initiator group.")
        return
    }
    #expect(
        initialGroupKey.documentScope.semanticTargetID
            == WebInspectorTarget.ID("worker")
    )
    #expect(
        initialGroupKey.documentScope.agentTargetID
            == WebInspectorTarget.ID("agent-a")
    )

    let laterScope = fixture.scope(
        targetID: "different-semantic-target",
        agentTargetID: "agent-a",
        domBindingEpoch: 9
    )
    _ = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("agent-a-request"),
            response: Network.Response(
                url: "https://example.test/worker.js",
                status: 200
            ),
            resourceType: .script,
            timestamp: 2
        ),
        scope: laterScope
    )
    _ = try fixture.store.reduce(
        .dataReceived(
            id: Network.Request.ID("agent-a-request"),
            dataLength: 10,
            encodedDataLength: 8,
            timestamp: 3
        ),
        scope: laterScope
    )
    _ = try fixture.store.reduce(
        .loadingFinished(
            id: Network.Request.ID("agent-a-request"),
            timestamp: 4,
            sourceMapURL: nil,
            metrics: nil
        ),
        scope: laterScope
    )

    let preservedEntry = try #require(
        fixture.store.entry(containing: firstAgentRequest.id)
    )
    let preservedRequest = try #require(
        fixture.store.request(for: firstAgentRequest.id)
    )
    #expect(preservedRequest.membership == firstAgentRequest.membership)
    #expect(
        preservedRequest.membership.semanticTargetID
            == WebInspectorTarget.ID("worker")
    )
    #expect(
        preservedRequest.membership.domBindingEpoch
            == ModelDOMBindingEpoch(rawValue: 1)
    )
    #expect(preservedEntry.id == firstAgentEntry.id)
    #expect(preservedEntry.groupKey == firstAgentEntry.groupKey)
    #expect(fixture.store.entries.count == 2)
}

@Test
func canonicalNetworkEntryRepresentativeIsChronologicalFirst() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let scope = fixture.scope(domBindingEpoch: 1)
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "first",
            url: "https://example.test/master.m3u8",
            initiatorNodeID: "video",
            resourceType: .media,
            timestamp: 1
        ),
        scope: scope
    )
    let firstID = try #require(fixture.store.requests.first?.id)
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "second",
            url: "https://example.test/segment-1.ts",
            initiatorNodeID: "video",
            resourceType: .media,
            timestamp: 2
        ),
        scope: scope
    )
    var entry = try #require(fixture.store.entries.first)
    #expect(entry.summary.primaryRequestID == firstID)
    #expect(entry.summary.url == "https://example.test/master.m3u8")
    #expect(entry.summary.statusCode == nil)

    _ = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("second"),
            response: Network.Response(
                url: "https://example.test/segment-1.ts",
                status: 206
            ),
            resourceType: .media,
            timestamp: 3
        ),
        scope: scope
    )
    entry = try #require(fixture.store.entries.first)
    #expect(entry.summary.primaryRequestID == firstID)
    #expect(entry.summary.url == "https://example.test/master.m3u8")
    #expect(entry.summary.statusCode == nil)

    _ = try fixture.store.reduce(
        .responseReceived(
            id: Network.Request.ID("first"),
            response: Network.Response(
                url: "https://example.test/master.m3u8",
                status: 200
            ),
            resourceType: .media,
            timestamp: 4
        ),
        scope: scope
    )
    entry = try #require(fixture.store.entries.first)
    #expect(entry.summary.primaryRequestID == firstID)
    #expect(entry.summary.statusCode == 200)
}

@Test
func canonicalNetworkGroupingUsesExactScopeAndChronology() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let domOne = fixture.scope(domBindingEpoch: 1)
    let domTwo = fixture.scope(domBindingEpoch: 2)
    let opaqueNavigationOne = fixture.scope(navigationEpoch: 1)
    let opaqueNavigationTwo = fixture.scope(navigationEpoch: 2)

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "dom-late",
            url: "https://example.test/dom-late",
            initiatorNodeID: "node",
            timestamp: 20
        ),
        scope: domOne
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "dom-early",
            url: "https://example.test/dom-early",
            initiatorNodeID: "node",
            timestamp: 10
        ),
        scope: domOne
    )
    let domEntry = try #require(fixture.store.entries.first)
    #expect(
        domEntry.requestIDs.map(\.rawRequestID) == [
            Network.Request.ID("dom-early"),
            Network.Request.ID("dom-late"),
        ])
    let domSnapshot = try #require(fixture.store.snapshot.entries.first)
    let searchTextByRequestID = Dictionary(
        uniqueKeysWithValues:
            fixture.store.snapshot.requests.map {
                ($0.record.id, $0.query.searchableText)
            }
    )
    #expect(
        domSnapshot.query.searchTexts
            == domEntry.requestIDs.map {
                searchTextByRequestID[$0]
            })
    guard case let .dom(domKey) = domEntry.groupKey else {
        Issue.record("Expected an exact DOM-backed group key.")
        return
    }
    #expect(domKey.documentScope.domBindingEpoch == .init(rawValue: 1))

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "dom-new-binding",
            url: "https://example.test/dom-new-binding",
            initiatorNodeID: "node",
            timestamp: 30
        ),
        scope: domTwo
    )
    #expect(fixture.store.entries.count == 2)

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "opaque-one",
            url: "https://example.test/opaque-one",
            initiatorNodeID: "node",
            timestamp: 40
        ),
        scope: opaqueNavigationOne
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "opaque-two",
            url: "https://example.test/opaque-two",
            initiatorNodeID: "node",
            timestamp: 50
        ),
        scope: opaqueNavigationOne
    )
    #expect(fixture.store.entries.count == 3)
    let opaqueEntry = try #require(
        fixture.store.entries.first {
            if case .opaqueInitiator = $0.groupKey {
                return true
            }
            return false
        })
    #expect(opaqueEntry.requestIDs.count == 2)

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "opaque-new-navigation",
            url: "https://example.test/opaque-new-navigation",
            initiatorNodeID: "node",
            timestamp: 60
        ),
        scope: opaqueNavigationTwo
    )
    #expect(fixture.store.entries.count == 4)

    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "singleton-one",
            url: "https://example.test/singleton-one",
            timestamp: 70
        ),
        scope: opaqueNavigationOne
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "singleton-two",
            url: "https://example.test/singleton-two",
            timestamp: 80
        ),
        scope: opaqueNavigationOne
    )
    #expect(fixture.store.entries.count == 6)
}

@Test
func canonicalNetworkEntryOrdinalsAreNeverReused() throws {
    var fixture = try CanonicalNetworkTestFixture()
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "first",
            url: "https://example.test/first",
            initiatorNodeID: "node",
            timestamp: 1
        ),
        scope: fixture.scope(domBindingEpoch: 1)
    )
    let firstOrdinal = try #require(fixture.store.entries.first?.id.ordinal)

    _ = fixture.store.clear()
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "second",
            url: "https://example.test/second",
            initiatorNodeID: "node",
            timestamp: 2
        ),
        scope: fixture.scope(domBindingEpoch: 1)
    )
    let secondOrdinal = try #require(fixture.store.entries.first?.id.ordinal)
    #expect(secondOrdinal > firstOrdinal)

    _ = try fixture.store.reset(
        attachmentGeneration: .init(rawValue: 1),
        pageGeneration: .init(rawValue: 2)
    )
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "third",
            url: "https://example.test/third",
            timestamp: 3
        ),
        scope: fixture.scope(pageGeneration: .init(rawValue: 2))
    )
    let thirdOrdinal = try #require(fixture.store.entries.first?.id.ordinal)
    #expect(thirdOrdinal > secondOrdinal)
}

@Test
func canonicalNetworkTargetLossDeletesWholeTargetScopedGroups() throws {
    var fixture = try CanonicalNetworkTestFixture()
    let targetA = fixture.scope(targetID: "target-a", domBindingEpoch: 1)
    let targetB = fixture.scope(targetID: "target-b", domBindingEpoch: 1)
    for rawID in ["a-one", "a-two"] {
        _ = try fixture.store.reduce(
            canonicalRequestWillBeSent(
                id: rawID,
                url: "https://example.test/\(rawID)",
                initiatorNodeID: "node",
                timestamp: rawID == "a-one" ? 1 : 2
            ),
            scope: targetA
        )
    }
    _ = try fixture.store.reduce(
        canonicalRequestWillBeSent(
            id: "b-one",
            url: "https://example.test/b-one",
            initiatorNodeID: "node",
            timestamp: 3
        ),
        scope: targetB
    )
    _ = try fixture.store.reduce(
        .webSocket(
            .created(
                id: Network.Request.ID("a-socket"),
                url: "wss://example.test/socket"
            )),
        scope: targetA
    )

    let targetAEntryID = try #require(
        fixture.store.entries.first(where: {
            $0.requestIDs.contains(where: {
                $0.agentTargetID == WebInspectorTarget.ID("target-a")
            })
        })?.id
    )
    let transaction = try #require(
        try fixture.store.targetWasLost(
            WebInspectorTarget.ID("target-a")
        )
    )
    #expect(transaction.requestChanges.count == 2)
    #expect(transaction.entryChanges == [.delete(targetAEntryID)])
    #expect(
        fixture.store.requests.map(\.id.agentTargetID) == [
            WebInspectorTarget.ID("target-b")
        ])
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.tombstonedRequestIDs.count == 3)
}

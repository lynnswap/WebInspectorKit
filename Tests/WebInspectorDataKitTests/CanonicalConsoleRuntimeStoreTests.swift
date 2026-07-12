import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private struct CanonicalConsoleRuntimeFixture {
    var store: CanonicalConsoleRuntimeStore
    let storeID: WebInspectorContainerStoreID
    let attachmentGeneration: WebInspectorContainerAttachmentGeneration
    let pageGeneration: WebInspectorPage.Generation

    init(
        projectsRuntimeContexts: Bool = true,
        attachment: UInt64 = 1,
        page: UInt64 = 1
    ) throws {
        storeID = WebInspectorContainerStoreID(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        attachmentGeneration = WebInspectorContainerAttachmentGeneration(
            rawValue: attachment
        )
        pageGeneration = WebInspectorPage.Generation(rawValue: page)
        store = CanonicalConsoleRuntimeStore(
            storeID: storeID,
            projectsRuntimeContexts: projectsRuntimeContexts
        )
        try store.reset(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: pageGeneration
        )
    }

    func scope(
        semanticTargetID: String = "page",
        agentTargetID: String? = nil,
        navigationEpoch: UInt64 = 1,
        runtimeBindingEpoch: UInt64? = 1,
        consoleBindingEpoch: UInt64? = 1,
        pageGeneration: WebInspectorPage.Generation? = nil
    ) -> ModelEventScope {
        let agentTargetID = agentTargetID ?? semanticTargetID
        return ModelEventScope(
            generation: pageGeneration ?? self.pageGeneration,
            target: ModelTarget(
                id: WebInspectorTarget.ID(semanticTargetID),
                kind: semanticTargetID == agentTargetID ? .page : .frame,
                frameID: FrameID("frame-\(semanticTargetID)"),
                parentFrameID: nil
            ),
            agentTarget: ModelTarget(
                id: WebInspectorTarget.ID(agentTargetID),
                kind: .page,
                frameID: FrameID("frame-\(agentTargetID)"),
                parentFrameID: nil
            ),
            navigationEpoch: ModelNavigationEpoch(rawValue: navigationEpoch),
            domBindingEpoch: nil,
            runtimeBindingEpoch: runtimeBindingEpoch.map(
                ModelRuntimeBindingEpoch.init(rawValue:)
            ),
            consoleBindingEpoch: consoleBindingEpoch.map(
                ModelConsoleBindingEpoch.init(rawValue:)
            )
        )
    }

    func networkResolution(
        rawID: String,
        agentTargetID: String = "network-agent"
    ) -> CanonicalConsoleNetworkRequestResolution {
        let rawRequestID = Network.Request.ID(rawID)
        return CanonicalConsoleNetworkRequestResolution(
            rawRequestID: rawRequestID,
            requestID: CanonicalNetworkRequestIDStorage(
                storeID: storeID,
                attachmentGeneration: attachmentGeneration,
                pageGeneration: pageGeneration,
                agentTargetID: WebInspectorTarget.ID(agentTargetID),
                rawRequestID: rawRequestID
            )
        )
    }
}

private func canonicalRuntimeContext(
    id: String,
    name: String = "main",
    frameID: String? = "frame",
    kind: Runtime.ContextKind = .normal
) -> Runtime.ExecutionContext {
    Runtime.ExecutionContext(
        id: Runtime.ExecutionContext.ID(id),
        name: name,
        frameID: frameID.map(FrameID.init),
        kind: kind
    )
}

private func canonicalConsoleMessage(
    text: String,
    repeatCount: Int = 1,
    parameters: [Runtime.RemoteObject] = [],
    networkRequestID: String? = nil,
    timestamp: Double? = 1
) -> Console.Message {
    Console.Message(
        source: Console.Source(rawValue: "console-api"),
        level: Console.Level(rawValue: "log"),
        type: Console.Kind(rawValue: "log"),
        text: text,
        url: "https://example.test/script.js",
        line: 4,
        column: 9,
        repeatCount: repeatCount,
        parameters: parameters,
        stackTrace: Console.StackTrace(callFrames: [
            Console.CallFrame(
                functionName: "run",
                url: "https://example.test/script.js",
                line: 4,
                column: 9
            )
        ]),
        networkRequestID: networkRequestID.map(Network.Request.ID.init),
        timestamp: timestamp
    )
}

@Test
func canonicalRuntimeIdentitySeparatesAgentAuthorityFromSemanticMembership() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let rootAgentScope = fixture.scope(
        semanticTargetID: "semantic-frame",
        agentTargetID: "root-runtime-agent",
        navigationEpoch: 7,
        runtimeBindingEpoch: 11
    )
    let frameAgentScope = fixture.scope(
        semanticTargetID: "other-frame",
        agentTargetID: "frame-runtime-agent",
        navigationEpoch: 3,
        runtimeBindingEpoch: 5
    )

    let first = try #require(
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "42")),
            scope: rootAgentScope
        )
    )
    let second = try #require(
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "42")),
            scope: frameAgentScope
        )
    )
    guard
        case let .insert(firstRecord, _) = first.runtimeContextChanges.first,
        case let .insert(secondRecord, _) = second.runtimeContextChanges.first
    else {
        Issue.record("Expected canonical Runtime insertions.")
        return
    }

    #expect(firstRecord.id != secondRecord.id)
    #expect(firstRecord.id.agentTargetID == WebInspectorTarget.ID("root-runtime-agent"))
    #expect(firstRecord.membership.semanticTargetID == WebInspectorTarget.ID("semantic-frame"))
    #expect(firstRecord.membership.navigationEpoch == ModelNavigationEpoch(rawValue: 7))
    #expect(firstRecord.membership.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 11))
    #expect(secondRecord.id.rawContextID == firstRecord.id.rawContextID)
    #expect(fixture.store.runtimeContextCount == 2)
}

@Test
func canonicalRuntimeIdentifierOnlyDestroyUsesThePhysicalAgentIndex() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let firstScope = fixture.scope(
        semanticTargetID: "frame-a",
        agentTargetID: "root-agent"
    )
    let secondScope = fixture.scope(
        semanticTargetID: "frame-b",
        agentTargetID: "frame-agent"
    )
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "same")),
        scope: firstScope
    )
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "same")),
        scope: secondScope
    )

    let transaction = try #require(
        try fixture.store.reduceRuntime(
            .executionContextDestroyed(Runtime.ExecutionContext.ID("same")),
            scope: fixture.scope(
                semanticTargetID: "root-agent",
                agentTargetID: "root-agent",
                runtimeBindingEpoch: 2
            )
        )
    )
    guard case let .delete(deletedID) = transaction.runtimeContextChanges.first else {
        Issue.record("Expected one Runtime deletion.")
        return
    }
    #expect(deletedID.agentTargetID == WebInspectorTarget.ID("root-agent"))
    #expect(fixture.store.runtimeContextCount == 1)
    #expect(
        fixture.store.runtimeContextID(
            agentTargetID: WebInspectorTarget.ID("frame-agent"),
            rawContextID: Runtime.ExecutionContext.ID("same")
        ) != nil
    )
}

@Test
func canonicalRuntimeClearTombstonesEveryContextInOneAgent() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    for (semanticTarget, rawID) in [("frame-a", "1"), ("frame-b", "2")] {
        _ = try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: rawID)),
            scope: fixture.scope(
                semanticTargetID: semanticTarget,
                agentTargetID: "root-agent",
                runtimeBindingEpoch: 1
            )
        )
    }
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "1")),
        scope: fixture.scope(agentTargetID: "other-agent")
    )

    let clearScope = fixture.scope(
        semanticTargetID: "root-agent",
        agentTargetID: "root-agent",
        runtimeBindingEpoch: 2
    )
    let transaction = try #require(
        try fixture.store.reduceRuntime(
            .executionContextsCleared,
            scope: clearScope
        )
    )
    #expect(transaction.runtimeContextChanges.count == 2)
    #expect(
        transaction.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("root-agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            )
        ]
    )
    #expect(fixture.store.runtimeContextCount == 1)

    let beforeReuse = fixture.store
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "1")),
            scope: clearScope
        )
    }
    #expect(fixture.store == beforeReuse)
}

@Test
func canonicalRuntimeDestroyRejectsSameGenerationReuseButResetPermitsNewIdentity() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let firstScope = fixture.scope(agentTargetID: "agent")
    let insertion = try #require(
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "replayed")),
            scope: firstScope
        )
    )
    guard case let .insert(firstRecord, _) = insertion.runtimeContextChanges.first else {
        Issue.record("Expected a Runtime insertion.")
        return
    }

    // Runtime.enable is idempotent in WebKit. A second create in the same
    // model generation is therefore not replay; it is identity reuse.
    let beforeDuplicate = fixture.store
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "replayed")),
            scope: firstScope
        )
    }
    #expect(fixture.store == beforeDuplicate)

    _ = try fixture.store.reduceRuntime(
        .executionContextDestroyed(Runtime.ExecutionContext.ID("replayed")),
        scope: firstScope
    )
    let beforeReuse = fixture.store
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "replayed")),
            scope: firstScope
        )
    }
    #expect(fixture.store == beforeReuse)

    let nextPage = WebInspectorPage.Generation(rawValue: 2)
    _ = try fixture.store.reset(
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: nextPage
    )
    let replayScope = fixture.scope(
        agentTargetID: "agent",
        pageGeneration: nextPage
    )
    let replay = try #require(
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "replayed")),
            scope: replayScope
        )
    )
    guard case let .insert(replayedRecord, _) = replay.runtimeContextChanges.first else {
        Issue.record("Expected Runtime replay after the authoritative reset.")
        return
    }
    #expect(replayedRecord.id != firstRecord.id)
    #expect(replayedRecord.id.pageGeneration == nextPage)
}

@Test
func canonicalRuntimeIgnoresDelayedDestroyForATombstonedContext() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let initialScope = fixture.scope(
        semanticTargetID: "frame",
        agentTargetID: "runtime-agent",
        runtimeBindingEpoch: 1
    )
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "late-destroy")),
        scope: initialScope
    )
    let clearedScope = fixture.scope(
        semanticTargetID: "frame",
        agentTargetID: "runtime-agent",
        runtimeBindingEpoch: 2
    )
    _ = try fixture.store.reduceRuntime(
        .executionContextsCleared,
        scope: clearedScope
    )

    let afterClear = fixture.store
    #expect(
        try fixture.store.reduceRuntime(
            .executionContextDestroyed(
                Runtime.ExecutionContext.ID("late-destroy")
            ),
            scope: clearedScope
        ) == nil
    )
    #expect(fixture.store == afterClear)

    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceRuntime(
            .executionContextDestroyed(
                Runtime.ExecutionContext.ID("never-observed")
            ),
            scope: clearedScope
        )
    }
    #expect(fixture.store == afterClear)
}

@Test
func canonicalSemanticNavigationDeletesOnlyPriorMembershipForThatTarget() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    for semanticTarget in ["frame-a", "frame-b"] {
        _ = try fixture.store.reduceRuntime(
            .executionContextCreated(
                canonicalRuntimeContext(id: "context-\(semanticTarget)")
            ),
            scope: fixture.scope(
                semanticTargetID: semanticTarget,
                agentTargetID: "root-agent",
                navigationEpoch: 1,
                runtimeBindingEpoch: 1
            )
        )
    }

    let navigationScope = fixture.scope(
        semanticTargetID: "frame-a",
        agentTargetID: "root-agent",
        navigationEpoch: 2,
        runtimeBindingEpoch: 2
    )
    let transaction = try #require(
        try fixture.store.semanticTargetNavigated(scope: navigationScope)
    )
    #expect(transaction.runtimeContextChanges.count == 1)
    #expect(fixture.store.runtimeContextCount == 1)
    #expect(
        transaction.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("root-agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            ),
            .semanticNavigation(
                semanticTargetID: WebInspectorTarget.ID("frame-a"),
                navigationEpoch: ModelNavigationEpoch(rawValue: 2)
            )
        ]
    )
}

@Test
func canonicalSemanticNavigationInvalidatesEveryAgentThroughSemanticAuthority() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    for agentTargetID in ["page-agent", "frame-agent"] {
        let scope = fixture.scope(
            semanticTargetID: "shared-frame",
            agentTargetID: agentTargetID,
            navigationEpoch: 1,
            runtimeBindingEpoch: 1,
            consoleBindingEpoch: 1
        )
        _ = try fixture.store.reduceRuntime(
            .executionContextCreated(
                canonicalRuntimeContext(id: "context-\(agentTargetID)")
            ),
            scope: scope
        )
        _ = try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(text: "message-\(agentTargetID)")
            ),
            scope: scope
        )
    }

    let transaction = try #require(
        try fixture.store.semanticTargetNavigated(
            scope: fixture.scope(
                semanticTargetID: "shared-frame",
                agentTargetID: "page-agent",
                navigationEpoch: 2,
                runtimeBindingEpoch: 2,
                consoleBindingEpoch: 1
            )
        )
    )

    #expect(transaction.runtimeContextChanges.count == 2)
    #expect(fixture.store.runtimeContextCount == 0)
    #expect(fixture.store.consoleMessageCount == 2)
    #expect(
        transaction.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("page-agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            ),
            .semanticNavigation(
                semanticTargetID: WebInspectorTarget.ID("shared-frame"),
                navigationEpoch: ModelNavigationEpoch(rawValue: 2)
            ),
        ]
    )
}

@Test
func canonicalConsoleRepeatAndClearAreScopedPerAgent() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let agentAScope = fixture.scope(agentTargetID: "console-a")
    let agentBScope = fixture.scope(agentTargetID: "console-b")
    let first = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(canonicalConsoleMessage(text: "first")),
            scope: agentAScope
        )
    )
    let second = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(canonicalConsoleMessage(text: "second")),
            scope: agentBScope
        )
    )
    guard
        case let .insert(firstRecord, _) = first.consoleMessageChanges.first,
        case let .insert(secondRecord, _) = second.consoleMessageChanges.first
    else {
        Issue.record("Expected Console insertions.")
        return
    }

    let repeatTransaction = try #require(
        try fixture.store.reduceConsole(
            .messageRepeatCountUpdated(count: 3, timestamp: 3),
            scope: agentAScope
        )
    )
    guard
        case let .update(repeatedID, _, query) =
            repeatTransaction.consoleMessageChanges.first
    else {
        Issue.record("Expected a Console repeat patch.")
        return
    }
    #expect(repeatedID == firstRecord.id)
    #expect(query?.repeatCount == 3)
    #expect(fixture.store.consoleMessage(for: secondRecord.id)?.repeatCount == 1)

    let clearScope = fixture.scope(
        agentTargetID: "console-a",
        consoleBindingEpoch: 2
    )
    let clear = try #require(
        try fixture.store.reduceConsole(
            .messagesCleared(reason: Console.ClearReason(rawValue: "frontend")),
            scope: clearScope
        )
    )
    #expect(clear.consoleMessageChanges == [.delete(firstRecord.id)])
    #expect(fixture.store.consoleMessage(for: secondRecord.id) != nil)
    #expect(
        clear.resourceInvalidations == [
            .consoleBinding(
                agentTargetID: WebInspectorTarget.ID("console-a"),
                epoch: ModelConsoleBindingEpoch(rawValue: 2)
            )
        ]
    )
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceConsole(
            .messageRepeatCountUpdated(count: 4, timestamp: 4),
            scope: clearScope
        )
    }
}

@Test
func canonicalConsoleOrdinalNeverReusesAcrossResetReattachOrReplay() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let payload = canonicalConsoleMessage(text: "backend replay")
    let first = try #require(
        try fixture.store.reduceConsole(.messageAdded(payload), scope: fixture.scope())
    )
    guard case let .insert(firstRecord, _) = first.consoleMessageChanges.first else {
        Issue.record("Expected first Console insertion.")
        return
    }

    _ = try fixture.store.reset(
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: WebInspectorPage.Generation(rawValue: 2)
    )
    let secondScope = fixture.scope(
        pageGeneration: WebInspectorPage.Generation(rawValue: 2)
    )
    let second = try #require(
        try fixture.store.reduceConsole(.messageAdded(payload), scope: secondScope)
    )
    guard case let .insert(secondRecord, _) = second.consoleMessageChanges.first else {
        Issue.record("Expected replay insertion after page reset.")
        return
    }

    let nextAttachment = WebInspectorContainerAttachmentGeneration(rawValue: 2)
    _ = try fixture.store.reset(
        attachmentGeneration: nextAttachment,
        pageGeneration: WebInspectorPage.Generation(rawValue: 1)
    )
    let thirdScope = fixture.scope(
        pageGeneration: WebInspectorPage.Generation(rawValue: 1)
    )
    let third = try #require(
        try fixture.store.reduceConsole(.messageAdded(payload), scope: thirdScope)
    )
    guard case let .insert(thirdRecord, _) = third.consoleMessageChanges.first else {
        Issue.record("Expected replay insertion after reattachment.")
        return
    }

    #expect(firstRecord.id.ordinal == 1)
    #expect(secondRecord.id.ordinal == 2)
    #expect(thirdRecord.id.ordinal == 3)
    #expect(firstRecord.id.attachmentGeneration == fixture.attachmentGeneration)
    #expect(thirdRecord.id.attachmentGeneration == nextAttachment)
}

@Test
func canonicalConsoleParameterSeedPreservesPayloadAndExactBindingAuthority() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let object = Runtime.RemoteObject(
        id: Runtime.RemoteObject.ID("remote-object"),
        kind: .object,
        subtype: Runtime.Subtype(rawValue: "array"),
        className: "Array",
        description: "Array(1)",
        value: .object(["inline": .bool(true)]),
        size: 1,
        preview: Runtime.ObjectPreview(
            kind: .array,
            subtype: Runtime.Subtype(rawValue: "array"),
            description: "[value]",
            lossless: true,
            overflow: false,
            properties: [Runtime.PropertyPreview(name: "0", value: "value")],
            entries: [Runtime.EntryPreview(key: "0", value: "value")],
            size: 1
        )
    )
    let scope = fixture.scope(
        semanticTargetID: "semantic-frame",
        agentTargetID: "console-runtime-agent",
        navigationEpoch: 9,
        runtimeBindingEpoch: 12,
        consoleBindingEpoch: 14
    )
    let transaction = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "parameter",
                    parameters: [object]
                )
            ),
            scope: scope
        )
    )
    guard
        case let .insert(record, _) = transaction.consoleMessageChanges.first,
        let seed = record.parameters.first
    else {
        Issue.record("Expected a Console parameter seed.")
        return
    }

    #expect(seed.payload.rawObjectID == Runtime.RemoteObject.ID("remote-object"))
    #expect(seed.payload.value == .object(["inline": .bool(true)]))
    #expect(
        seed.payload.preview?.properties == [
            CanonicalRuntimePropertyPreview(
                Runtime.PropertyPreview(name: "0", value: "value")
            )
        ])
    #expect(seed.authority.ownerMessageID == record.id)
    #expect(seed.authority.semanticTargetID == WebInspectorTarget.ID("semantic-frame"))
    #expect(seed.authority.agentTargetID == WebInspectorTarget.ID("console-runtime-agent"))
    #expect(seed.authority.navigationEpoch == ModelNavigationEpoch(rawValue: 9))
    #expect(seed.authority.runtimeBindingEpoch == ModelRuntimeBindingEpoch(rawValue: 12))
    #expect(seed.authority.consoleBindingEpoch == ModelConsoleBindingEpoch(rawValue: 14))
    #expect(record.stackTrace?.callFrames.first?.functionName == "run")
}

@Test
func canonicalConsoleNetworkReferenceResolvesAfterRequestInsertionWithoutAgentGuessing() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let rawRequestID = Network.Request.ID("request")
    let transaction = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "network failure",
                    networkRequestID: rawRequestID.rawValue
                )
            ),
            scope: fixture.scope(agentTargetID: "console-agent")
        )
    )
    guard case let .insert(record, _) = transaction.consoleMessageChanges.first else {
        Issue.record("Expected unresolved Console insertion.")
        return
    }
    #expect(
        record.networkRequestReference == .unresolved(rawRequestID: rawRequestID)
    )
    #expect(
        fixture.store.unresolvedConsoleMessageIDs(for: rawRequestID) == [record.id]
    )

    let resolution = fixture.networkResolution(
        rawID: rawRequestID.rawValue,
        agentTargetID: "different-network-agent"
    )
    let resolutionTransaction = try #require(
        try fixture.store.resolveNetworkRequest(resolution)
    )
    guard
        case let .update(id, patch, query) =
            resolutionTransaction.consoleMessageChanges.first
    else {
        Issue.record("Expected a Network-reference patch.")
        return
    }
    #expect(id == record.id)
    #expect(
        patch
            == .networkRequestReference(
                .resolved(
                    rawRequestID: rawRequestID,
                    requestID: resolution.requestID
                )
            )
    )
    #expect(query == nil)
    #expect(
        fixture.store.consoleMessage(for: record.id)?.networkRequestReference
            == .resolved(
                rawRequestID: rawRequestID,
                requestID: resolution.requestID
            )
    )
}

@Test
func canonicalConsoleNetworkReferenceCanResolveAtomicallyWhenRequestAlreadyExists() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let resolution = fixture.networkResolution(rawID: "already-known")
    let transaction = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "known",
                    networkRequestID: "already-known"
                )
            ),
            scope: fixture.scope(agentTargetID: "console-agent"),
            networkRequestResolution: resolution
        )
    )
    guard case let .insert(record, _) = transaction.consoleMessageChanges.first else {
        Issue.record("Expected resolved Console insertion.")
        return
    }
    #expect(
        record.networkRequestReference
            == .resolved(
                rawRequestID: Network.Request.ID("already-known"),
                requestID: resolution.requestID
            )
    )
    #expect(
        fixture.store.unresolvedConsoleMessageIDs(
            for: Network.Request.ID("already-known")
        ).isEmpty
    )
}

@Test
func consoleOnlyStoreConsumesRuntimeClearWithoutProjectingRuntimeContexts() throws {
    var fixture = try CanonicalConsoleRuntimeFixture(projectsRuntimeContexts: false)
    let messageTransaction = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "object",
                    parameters: [
                        Runtime.RemoteObject(
                            id: Runtime.RemoteObject.ID("object"),
                            kind: .object
                        )
                    ]
                )
            ),
            scope: fixture.scope(
                agentTargetID: "agent",
                runtimeBindingEpoch: 1
            )
        )
    )
    guard case let .insert(message, _) = messageTransaction.consoleMessageChanges.first else {
        Issue.record("Expected Console insertion.")
        return
    }

    let clear = try #require(
        try fixture.store.reduceRuntime(
            .executionContextsCleared,
            scope: fixture.scope(
                agentTargetID: "agent",
                runtimeBindingEpoch: 2
            )
        )
    )
    #expect(clear.runtimeContextChanges.isEmpty)
    #expect(clear.consoleMessageChanges.isEmpty)
    #expect(
        clear.resourceInvalidations == [
            .runtimeBinding(
                agentTargetID: WebInspectorTarget.ID("agent"),
                epoch: ModelRuntimeBindingEpoch(rawValue: 2)
            )
        ]
    )
    #expect(fixture.store.consoleMessage(for: message.id) != nil)
    #expect(fixture.store.runtimeContextCount == 0)
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "context")),
            scope: fixture.scope(agentTargetID: "agent")
        )
    }
}

@Test
func canonicalTargetLossDeletesPhysicalAndSemanticRuntimeMembershipAndAgentConsole() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "physical")),
        scope: fixture.scope(
            semanticTargetID: "other-semantic",
            agentTargetID: "lost-target"
        )
    )
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "semantic")),
        scope: fixture.scope(
            semanticTargetID: "lost-target",
            agentTargetID: "surviving-agent"
        )
    )
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "survivor")),
        scope: fixture.scope(
            semanticTargetID: "survivor",
            agentTargetID: "surviving-agent"
        )
    )
    _ = try fixture.store.reduceConsole(
        .messageAdded(canonicalConsoleMessage(text: "removed")),
        scope: fixture.scope(agentTargetID: "lost-target")
    )
    _ = try fixture.store.reduceConsole(
        .messageAdded(canonicalConsoleMessage(text: "kept")),
        scope: fixture.scope(agentTargetID: "surviving-agent")
    )

    let transaction = fixture.store.targetWasLost(
        WebInspectorTarget.ID("lost-target")
    )
    #expect(transaction.runtimeContextChanges.count == 2)
    #expect(transaction.consoleMessageChanges.count == 1)
    #expect(transaction.resourceInvalidations == [.targetLost(WebInspectorTarget.ID("lost-target"))])
    #expect(fixture.store.runtimeContextCount == 1)
    #expect(fixture.store.consoleMessageCount == 1)
}

@Test
func canonicalSemanticTargetLossDeletesOnlyItsConsoleMessagesAndResourceSeeds() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let keptTransaction = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(canonicalConsoleMessage(text: "kept")),
            scope: fixture.scope(
                semanticTargetID: "surviving-semantic-target",
                agentTargetID: "shared-console-agent"
            )
        )
    )
    let removedTransaction = try #require(
        try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "removed",
                    parameters: [
                        Runtime.RemoteObject(
                            id: Runtime.RemoteObject.ID("removed-object"),
                            kind: .object
                        )
                    ],
                    networkRequestID: "removed-request"
                )
            ),
            scope: fixture.scope(
                semanticTargetID: "lost-semantic-target",
                agentTargetID: "shared-console-agent"
            )
        )
    )
    guard
        case let .insert(removedRecord, _) =
            removedTransaction.consoleMessageChanges.first,
        case let .insert(keptRecord, _) =
            keptTransaction.consoleMessageChanges.first
    else {
        Issue.record("Expected two semantic Console insertions.")
        return
    }
    #expect(removedRecord.parameters.count == 1)
    #expect(
        fixture.store.unresolvedConsoleMessageIDs(
            for: Network.Request.ID("removed-request")
        ) == [removedRecord.id]
    )

    let loss = fixture.store.targetWasLost(
        WebInspectorTarget.ID("lost-semantic-target")
    )
    #expect(loss.consoleMessageChanges == [.delete(removedRecord.id)])
    #expect(fixture.store.consoleMessage(for: removedRecord.id) == nil)
    #expect(fixture.store.consoleMessage(for: keptRecord.id) != nil)
    #expect(
        fixture.store.unresolvedConsoleMessageIDs(
            for: Network.Request.ID("removed-request")
        ).isEmpty
    )

    // The per-agent repeat owner must fall back to the newest surviving
    // message when target loss removes only one semantic membership.
    _ = try fixture.store.reduceConsole(
        .messageRepeatCountUpdated(count: 2, timestamp: 2),
        scope: fixture.scope(
            semanticTargetID: "surviving-semantic-target",
            agentTargetID: "shared-console-agent"
        )
    )
    #expect(fixture.store.consoleMessage(for: keptRecord.id)?.repeatCount == 2)
}

@Test
func canonicalReducerThrowingMutationsHaveStrongExceptionGuarantee() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let scope = fixture.scope(agentTargetID: "agent")
    _ = try fixture.store.reduceRuntime(
        .executionContextCreated(canonicalRuntimeContext(id: "context")),
        scope: scope
    )
    _ = try fixture.store.reduceConsole(
        .messageAdded(canonicalConsoleMessage(text: "message")),
        scope: scope
    )

    var before = fixture.store
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceRuntime(
            .executionContextCreated(canonicalRuntimeContext(id: "context")),
            scope: scope
        )
    }
    #expect(fixture.store == before)

    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceConsole(
            .messageRepeatCountUpdated(count: 1, timestamp: 2),
            scope: scope
        )
    }
    #expect(fixture.store == before)

    let wrongResolution = CanonicalConsoleNetworkRequestResolution(
        rawRequestID: Network.Request.ID("wrong"),
        requestID: CanonicalNetworkRequestIDStorage(
            storeID: fixture.storeID,
            attachmentGeneration: fixture.attachmentGeneration,
            pageGeneration: fixture.pageGeneration,
            agentTargetID: WebInspectorTarget.ID("network-agent"),
            rawRequestID: Network.Request.ID("different")
        )
    )
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "invalid",
                    networkRequestID: "wrong"
                )
            ),
            scope: scope,
            networkRequestResolution: wrongResolution
        )
    }
    #expect(fixture.store == before)

    before = fixture.store
    #expect(throws: CanonicalConsoleRuntimeStoreError.self) {
        try fixture.store.reset(
            attachmentGeneration: fixture.attachmentGeneration,
            pageGeneration: fixture.pageGeneration
        )
    }
    #expect(fixture.store == before)
}

@Test
func canonicalBindingEpochsAreRequiredAndConsoleRepeatCannotCrossClear() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let missingRuntime = fixture.scope(runtimeBindingEpoch: nil)
    let before = fixture.store
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceConsole(
            .messageAdded(canonicalConsoleMessage(text: "invalid")),
            scope: missingRuntime
        )
    }
    #expect(fixture.store == before)

    let originalScope = fixture.scope(consoleBindingEpoch: 4)
    _ = try fixture.store.reduceConsole(
        .messageAdded(canonicalConsoleMessage(text: "original")),
        scope: originalScope
    )
    let beforeMismatch = fixture.store
    #expect(throws: CanonicalConsoleRuntimeProtocolViolation.self) {
        try fixture.store.reduceConsole(
            .messageRepeatCountUpdated(count: 2, timestamp: 2),
            scope: fixture.scope(consoleBindingEpoch: 5)
        )
    }
    #expect(fixture.store == beforeMismatch)
}

@Test
func canonicalConsoleRuntimeNormalEventsDoNotBuildOrScanSnapshots() throws {
    var fixture = try CanonicalConsoleRuntimeFixture()
    let scope = fixture.scope(agentTargetID: "agent")
    for index in 0..<10_000 {
        _ = try fixture.store.reduceConsole(
            .messageAdded(
                canonicalConsoleMessage(
                    text: "message-\(index)",
                    timestamp: Double(index)
                )
            ),
            scope: scope
        )
    }
    fixture.store.resetPerformanceCountersForTesting()

    _ = try fixture.store.reduceConsole(
        .messageRepeatCountUpdated(count: 2, timestamp: 10_001),
        scope: scope
    )
    #expect(fixture.store.performanceCounters.incrementalRecordVisitCount == 1)
    #expect(fixture.store.performanceCounters.fullSnapshotBuildCount == 0)
    #expect(fixture.store.performanceCounters.fullSnapshotRecordVisitCount == 0)
    #expect(fixture.store.performanceCounters.unrelatedRecordScanCount == 0)

    let snapshot = fixture.store.snapshot()
    #expect(snapshot.consoleMessages.count == 10_000)
    #expect(fixture.store.performanceCounters.fullSnapshotBuildCount == 1)
    #expect(fixture.store.performanceCounters.fullSnapshotRecordVisitCount == 10_000)
}

@Test
func canonicalConsoleRuntimeStoreAndTransactionsAreSendableValues() throws {
    let fixture = try CanonicalConsoleRuntimeFixture()
    func requireSendable<T: Sendable>(_: T) {}
    requireSendable(fixture.store)
    requireSendable(CanonicalConsoleRuntimeTransaction())
    requireSendable(fixture.storeID)
}

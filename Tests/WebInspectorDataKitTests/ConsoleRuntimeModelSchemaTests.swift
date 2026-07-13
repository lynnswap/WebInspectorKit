import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func legacyConsoleRuntimeIDsCannotBeConvertedIntoCanonicalAuthority() {
    #expect(ConsoleMessage.ID(0).canonicalStorage == nil)
    #expect(
        RuntimeContext.ID(
            Runtime.ExecutionContext.ID("legacy-runtime")
        ).canonicalStorage == nil
    )
}

@MainActor
@Test
func consoleRuntimeSchemasDriveGenericFetchFRCAndContextLocalIdentity() async throws {
    let fixture = ConsoleRuntimeSchemaFixture()
    let initialMessage = fixture.consoleMessage(
        ordinal: 1,
        text: "initial",
        repeatCount: 1
    )
    let initialContext = fixture.runtimeContext(ordinal: 1, rawID: "runtime-1")
    let snapshot = fixture.snapshot(
        runtimeContexts: [initialContext],
        consoleMessages: [initialMessage]
    )
    let registry = fixture.registry
    let firstContext = WebInspectorModelContext(
        modelSchemaRegistry: registry,
        isolation: MainActor.shared
    )
    let secondContext = WebInspectorModelContext(
        modelSchemaRegistry: registry,
        isolation: MainActor.shared
    )
    try await publishInitial(snapshot, to: firstContext)
    try await publishInitial(snapshot, to: secondContext)

    let messageID = ConsoleMessage.ID(canonical: initialMessage.record.id)
    let runtimeID = RuntimeContext.ID(canonical: initialContext.record.id)
    #expect(
        try await firstContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<ConsoleMessage>()
        ) == [messageID]
    )
    #expect(
        try await firstContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<WebInspectorDataKit.RuntimeContext>()
        ) == [runtimeID]
    )

    let firstMessage = try #require(firstContext.model(for: messageID))
    let sameMessage = try #require(firstContext.model(for: messageID))
    let otherContextMessage = try #require(secondContext.model(for: messageID))
    #expect(firstMessage === sameMessage)
    #expect(firstMessage !== otherContextMessage)
    #expect(firstMessage.id.canonicalStorage == initialMessage.record.id)
    #expect(firstMessage.parameters.count == 1)
    #expect(firstMessage.parameters[0].canRequestProperties)
    #expect(firstMessage.parameters[0].proxyID == nil)

    let firstRuntime = try #require(firstContext.model(for: runtimeID))
    let otherContextRuntime = try #require(secondContext.model(for: runtimeID))
    #expect(firstRuntime !== otherContextRuntime)
    #expect(firstRuntime.id.canonicalStorage == initialContext.record.id)

    let controller = try await WebInspectorFetchedResultsController<
        ConsoleMessage,
        Never
    >(
        modelContext: firstContext,
        isolation: MainActor.shared
    )
    #expect(controller.snapshot.itemIDs == [messageID])
    #expect(controller.revision == 0)

    let patch = CanonicalConsoleMessagePatch.repeatCount(
        count: 3,
        timestamp: 42
    )
    var updatedRecord = initialMessage.record
    updatedRecord.apply(patch)
    let update = WebInspectorCanonicalModelTransaction(
        consoleRuntime: CanonicalConsoleRuntimeTransaction(
            consoleMessageChanges: [
                .update(
                    id: initialMessage.record.id,
                    patch: patch,
                    query: updatedRecord.queryProjection
                )
            ]
        )
    )
    try await publishChanges(update, revision: 1, to: firstContext)
    try await publishChanges(update, revision: 1, to: secondContext)

    #expect(firstMessage.repeatCount == 3)
    #expect(firstMessage.timestamp == 42)
    #expect(otherContextMessage.repeatCount == 3)
    #expect(controller.revision == 1)
    #expect(controller.snapshot.itemIDs == [messageID])
    #expect(
        try await firstContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<ConsoleMessage>(
                predicate: #Predicate { $0.repeatCount == 3 }
            )
        ) == [messageID]
    )

    let networkStorage = CanonicalNetworkRequestIDStorage(
        storeID: fixture.storeID,
        attachmentGeneration: fixture.attachmentGeneration,
        pageGeneration: fixture.pageGeneration,
        agentTargetID: WebInspectorTarget.ID("page"),
        rawRequestID: Network.Request.ID("network-1")
    )
    let networkPatch = CanonicalConsoleMessagePatch.networkRequestReference(
        .resolved(
            rawRequestID: Network.Request.ID("network-1"),
            requestID: networkStorage
        )
    )
    let networkUpdate = WebInspectorCanonicalModelTransaction(
        consoleRuntime: CanonicalConsoleRuntimeTransaction(
            consoleMessageChanges: [
                .update(
                    id: initialMessage.record.id,
                    patch: networkPatch,
                    query: nil
                )
            ]
        )
    )
    try await publishChanges(networkUpdate, revision: 2, to: firstContext)
    try await publishChanges(networkUpdate, revision: 2, to: secondContext)
    #expect(firstMessage.networkRequestID?.canonicalStorage == networkStorage)
    #expect(otherContextMessage.networkRequestID?.canonicalStorage == networkStorage)
    #expect(controller.revision == 2)

    await controller.close()
    await firstContext.close()
    #expect(firstMessage.modelContext == nil)
    #expect(firstMessage.parameters[0].canRequestProperties == false)
    #expect(firstRuntime.modelContext == nil)
    #expect(otherContextMessage.modelContext === secondContext)
    #expect(otherContextRuntime.modelContext === secondContext)
    await secondContext.close()
}

@MainActor
@Test
func consoleRuntimeSchemasApplyClearNavigationTargetAndDetachInvalidation() async throws {
    let fixture = ConsoleRuntimeSchemaFixture()
    let clearedMessage = fixture.consoleMessage(
        ordinal: 1,
        semanticTarget: "clear-target",
        agentTarget: "clear-agent",
        text: "clear"
    )
    let navigationMessage = fixture.consoleMessage(
        ordinal: 2,
        semanticTarget: "navigation-target",
        agentTarget: "navigation-agent",
        text: "navigation"
    )
    let targetMessage = fixture.consoleMessage(
        ordinal: 3,
        semanticTarget: "lost-target",
        agentTarget: "lost-agent",
        text: "target"
    )
    let detachMessage = fixture.consoleMessage(
        ordinal: 4,
        semanticTarget: "detach-target",
        agentTarget: "detach-agent",
        text: "detach"
    )
    let clearedContext = fixture.runtimeContext(
        ordinal: 1,
        rawID: "clear-context",
        semanticTarget: "clear-target",
        agentTarget: "clear-agent"
    )
    let navigationContext = fixture.runtimeContext(
        ordinal: 2,
        rawID: "navigation-context",
        semanticTarget: "navigation-target",
        agentTarget: "navigation-agent"
    )
    let targetContext = fixture.runtimeContext(
        ordinal: 3,
        rawID: "target-context",
        semanticTarget: "lost-target",
        agentTarget: "lost-agent"
    )
    let detachContext = fixture.runtimeContext(
        ordinal: 4,
        rawID: "detach-context",
        semanticTarget: "detach-target",
        agentTarget: "detach-agent"
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await publishInitial(
        fixture.snapshot(
            runtimeContexts: [
                clearedContext,
                navigationContext,
                targetContext,
                detachContext,
            ],
            consoleMessages: [
                clearedMessage,
                navigationMessage,
                targetMessage,
                detachMessage,
            ]
        ),
        to: context
    )

    let clearedModel = try #require(
        context.model(
            for: ConsoleMessage.ID(canonical: clearedMessage.record.id)
        )
    )
    let navigationModel = try #require(
        context.model(
            for: ConsoleMessage.ID(canonical: navigationMessage.record.id)
        )
    )
    let targetModel = try #require(
        context.model(
            for: ConsoleMessage.ID(canonical: targetMessage.record.id)
        )
    )
    let detachModel = try #require(
        context.model(
            for: ConsoleMessage.ID(canonical: detachMessage.record.id)
        )
    )
    let clearedRuntimeModel = try #require(
        context.model(
            for: RuntimeContext.ID(canonical: clearedContext.record.id)
        )
    )
    let navigationRuntimeModel = try #require(
        context.model(
            for: RuntimeContext.ID(canonical: navigationContext.record.id)
        )
    )
    let targetRuntimeModel = try #require(
        context.model(
            for: RuntimeContext.ID(canonical: targetContext.record.id)
        )
    )
    let detachRuntimeModel = try #require(
        context.model(
            for: RuntimeContext.ID(canonical: detachContext.record.id)
        )
    )

    try await publishChanges(
        WebInspectorCanonicalModelTransaction(
            consoleRuntime: CanonicalConsoleRuntimeTransaction(
                consoleMessageChanges: [
                    .delete(clearedMessage.record.id)
                ],
                resourceInvalidations: [
                    .consoleBinding(
                        agentTargetID: WebInspectorTarget.ID("clear-agent"),
                        epoch: ModelConsoleBindingEpoch(rawValue: 2)
                    )
                ]
            )
        ),
        revision: 1,
        to: context
    )
    #expect(clearedModel.modelContext == nil)
    #expect(clearedModel.parameters[0].canRequestProperties == false)
    #expect(clearedRuntimeModel.modelContext === context)

    try await publishChanges(
        WebInspectorCanonicalModelTransaction(
            consoleRuntime: CanonicalConsoleRuntimeTransaction(
                runtimeContextChanges: [
                    .delete(navigationContext.record.id)
                ],
                resourceInvalidations: [
                    .semanticNavigation(
                        semanticTargetID: WebInspectorTarget.ID(
                            "navigation-target"
                        ),
                        navigationEpoch: ModelNavigationEpoch(rawValue: 2)
                    )
                ]
            )
        ),
        revision: 2,
        to: context
    )
    #expect(navigationRuntimeModel.modelContext == nil)
    #expect(navigationModel.modelContext === context)
    #expect(navigationModel.parameters[0].canRequestProperties == false)

    try await publishChanges(
        WebInspectorCanonicalModelTransaction(
            consoleRuntime: CanonicalConsoleRuntimeTransaction(
                runtimeContextChanges: [
                    .delete(targetContext.record.id)
                ],
                consoleMessageChanges: [
                    .delete(targetMessage.record.id)
                ],
                resourceInvalidations: [
                    .targetLost(WebInspectorTarget.ID("lost-target"))
                ]
            )
        ),
        revision: 3,
        to: context
    )
    #expect(targetRuntimeModel.modelContext == nil)
    #expect(targetModel.modelContext == nil)
    #expect(targetModel.parameters[0].canRequestProperties == false)

    try await publishChanges(
        WebInspectorCanonicalModelTransaction(
            consoleRuntime: CanonicalConsoleRuntimeTransaction(
                runtimeContextChanges: [
                    .delete(clearedContext.record.id),
                    .delete(detachContext.record.id),
                ],
                consoleMessageChanges: [
                    .delete(navigationMessage.record.id),
                    .delete(detachMessage.record.id),
                ],
                resourceInvalidations: [
                    .attachmentDetached(
                        attachmentGeneration: fixture.attachmentGeneration,
                        pageGeneration: fixture.pageGeneration
                    )
                ]
            )
        ),
        revision: 4,
        to: context
    )
    #expect(clearedRuntimeModel.modelContext == nil)
    #expect(detachRuntimeModel.modelContext == nil)
    #expect(navigationModel.modelContext == nil)
    #expect(detachModel.modelContext == nil)
    #expect(detachModel.parameters[0].canRequestProperties == false)
    #expect(
        try await context.fetchIdentifiers(
            WebInspectorFetchDescriptor<ConsoleMessage>()
        ).isEmpty
    )
    #expect(
        try await context.fetchIdentifiers(
            WebInspectorFetchDescriptor<WebInspectorDataKit.RuntimeContext>()
        ).isEmpty
    )
    await context.close()
}

@MainActor
@Test
func consoleSchemaInvalidatesOnlyMatchingMaterializedMessageGraphs() async throws {
    let fixture = ConsoleRuntimeSchemaFixture()
    let first = fixture.consoleMessage(
        ordinal: 1,
        semanticTarget: "first-target",
        agentTarget: "first-agent",
        text: "first"
    )
    let second = fixture.consoleMessage(
        ordinal: 2,
        semanticTarget: "second-target",
        agentTarget: "second-agent",
        text: "second"
    )
    let runtime = fixture.runtimeContext(
        ordinal: 1,
        rawID: "first-runtime",
        semanticTarget: "first-target",
        agentTarget: "first-agent"
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await publishInitial(
        fixture.snapshot(
            runtimeContexts: [runtime],
            consoleMessages: [first, second]
        ),
        to: context
    )
    let firstModel = try #require(
        context.model(for: ConsoleMessage.ID(canonical: first.record.id))
    )
    let runtimeModel = try #require(
        context.model(for: RuntimeContext.ID(canonical: runtime.record.id))
    )
    #expect(
        context.registeredModel(
            for: ConsoleMessage.ID(canonical: second.record.id)
        ) == nil
    )

    try await publishChanges(
        WebInspectorCanonicalModelTransaction(
            consoleRuntime: CanonicalConsoleRuntimeTransaction(
                resourceInvalidations: [
                    .runtimeBinding(
                        agentTargetID: WebInspectorTarget.ID("first-agent"),
                        epoch: ModelRuntimeBindingEpoch(rawValue: 2)
                    )
                ]
            )
        ),
        revision: 1,
        to: context
    )
    #expect(firstModel.parameters[0].canRequestProperties == false)
    #expect(runtimeModel.modelContext === context)
    #expect(
        context.registeredModel(
            for: ConsoleMessage.ID(canonical: second.record.id)
        ) == nil
    )
    let secondModel = try #require(
        context.model(for: ConsoleMessage.ID(canonical: second.record.id))
    )
    #expect(secondModel.parameters[0].canRequestProperties)
    await context.close()
}

@MainActor
@Test
func consoleSchemaResetRebuildsResourcesWithoutReplacingPersistentIdentity() async throws {
    let fixture = ConsoleRuntimeSchemaFixture()
    let entry = fixture.consoleMessage(ordinal: 1, text: "rebase")
    let snapshot = fixture.snapshot(
        runtimeContexts: [],
        consoleMessages: [entry]
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await publishInitial(snapshot, to: context)
    let id = ConsoleMessage.ID(canonical: entry.record.id)
    let model = try #require(context.model(for: id))
    let oldParameter = try #require(model.parameters.first)

    try await publishReset(snapshot, revision: 1, to: context)

    let sameModel = try #require(context.model(for: id))
    let newParameter = try #require(sameModel.parameters.first)
    #expect(sameModel === model)
    #expect(newParameter !== oldParameter)
    #expect(oldParameter.canRequestProperties == false)
    #expect(newParameter.canRequestProperties)
    await context.close()
}

private struct ConsoleRuntimeSchemaFixture {
    let storeID = WebInspectorContainerStoreID()
    let attachmentGeneration = WebInspectorContainerAttachmentGeneration(
        rawValue: 1
    )
    let pageGeneration = WebInspectorPage.Generation(rawValue: 1)

    var registry: WebInspectorModelSchemaRegistry {
        WebInspectorModelSchemaRegistry([
            WebInspectorModelSchemaRegistration(.consoleMessage),
            WebInspectorModelSchemaRegistration(.runtimeContext),
        ])
    }

    func consoleMessage(
        ordinal: UInt64,
        semanticTarget: String = "page",
        agentTarget: String = "page",
        text: String,
        repeatCount: Int = 1
    ) -> CanonicalConsoleMessageSnapshotEntry {
        let id = CanonicalConsoleMessageIDStorage(
            storeID: storeID,
            attachmentGeneration: attachmentGeneration,
            ordinal: ordinal
        )
        let semanticTargetID = WebInspectorTarget.ID(semanticTarget)
        let agentTargetID = WebInspectorTarget.ID(agentTarget)
        let membership = CanonicalConsoleMessageMembership(
            pageGeneration: pageGeneration,
            semanticTargetID: semanticTargetID,
            agentTargetID: agentTargetID,
            navigationEpoch: ModelNavigationEpoch(rawValue: 1),
            runtimeBindingEpoch: ModelRuntimeBindingEpoch(rawValue: 1),
            consoleBindingEpoch: ModelConsoleBindingEpoch(rawValue: 1)
        )
        let seed = CanonicalConsoleParameterResourceSeed(
            payload: CanonicalRuntimeRemoteObjectPayload(
                Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("remote-\(ordinal)"),
                    kind: .object,
                    className: "Object",
                    description: "parameter-\(ordinal)"
                )
            ),
            authority: CanonicalConsoleParameterAuthority(
                ownerMessageID: id,
                pageGeneration: pageGeneration,
                semanticTargetID: semanticTargetID,
                agentTargetID: agentTargetID,
                navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                runtimeBindingEpoch: ModelRuntimeBindingEpoch(rawValue: 1),
                consoleBindingEpoch: ModelConsoleBindingEpoch(rawValue: 1)
            )
        )
        let record = CanonicalConsoleMessageRecord(
            id: id,
            membership: membership,
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "log"),
            kind: Console.Kind(rawValue: "log"),
            text: text,
            url: "https://example.com/\(ordinal)",
            line: Int(ordinal),
            column: 1,
            repeatCount: repeatCount,
            parameters: [seed],
            stackTrace: nil,
            networkRequestReference: nil,
            timestamp: Double(ordinal)
        )
        return CanonicalConsoleMessageSnapshotEntry(
            record: record,
            query: record.queryProjection
        )
    }

    func runtimeContext(
        ordinal: UInt64,
        rawID: String,
        semanticTarget: String = "page",
        agentTarget: String = "page"
    ) -> CanonicalRuntimeContextSnapshotEntry {
        let record = CanonicalRuntimeContextRecord(
            id: CanonicalRuntimeContextIDStorage(
                storeID: storeID,
                attachmentGeneration: attachmentGeneration,
                pageGeneration: pageGeneration,
                agentTargetID: WebInspectorTarget.ID(agentTarget),
                rawContextID: Runtime.ExecutionContext.ID(rawID)
            ),
            insertionOrdinal: ordinal,
            membership: CanonicalRuntimeContextMembership(
                semanticTargetID: WebInspectorTarget.ID(semanticTarget),
                navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                runtimeBindingEpoch: ModelRuntimeBindingEpoch(rawValue: 1)
            ),
            name: rawID,
            frameID: FrameID("frame-\(ordinal)"),
            kind: .normal
        )
        return CanonicalRuntimeContextSnapshotEntry(
            record: record,
            query: record.queryProjection
        )
    }

    func snapshot(
        runtimeContexts: [CanonicalRuntimeContextSnapshotEntry],
        consoleMessages: [CanonicalConsoleMessageSnapshotEntry]
    ) -> WebInspectorCanonicalModelSnapshot {
        WebInspectorCanonicalModelSnapshot(
            binding: nil,
            network: nil,
            DOM: nil,
            CSS: nil,
            consoleRuntime: CanonicalConsoleRuntimeSnapshot(
                runtimeContexts: runtimeContexts,
                consoleMessages: consoleMessages
            )
        )
    }
}

@MainActor
private func publishInitial(
    _ snapshot: WebInspectorCanonicalModelSnapshot,
    to context: WebInspectorModelContext
) async throws {
    let transaction = context.modelSchemaContextCore.initial(
        at: 0,
        snapshot: snapshot
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

@MainActor
private func publishChanges(
    _ transaction: WebInspectorCanonicalModelTransaction,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    let schemaTransaction = context.modelSchemaContextCore.changes(
        at: revision,
        transaction: transaction
    )
    let commit = try await schemaTransaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

@MainActor
private func publishReset(
    _ snapshot: WebInspectorCanonicalModelSnapshot,
    revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    let schemaTransaction = context.modelSchemaContextCore.reset(
        at: revision,
        snapshot: snapshot
    )
    let commit = try await schemaTransaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

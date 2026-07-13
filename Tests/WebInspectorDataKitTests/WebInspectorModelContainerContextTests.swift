import Observation
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private struct ContainerDriverModelID: WebInspectorPersistentIdentifier {
    typealias Model = ContainerDriverModel

    let rawValue: Int
}

private struct ContainerDriverQueryValue: Identifiable, Sendable {
    let id: ContainerDriverModelID
    let value: Int
}

private struct ContainerDriverRecord: WebInspectorModelRecord {
    enum Patch: Sendable {
        case value(Int)
    }

    var value: Int

    mutating func apply(_ patch: Patch) {
        switch patch {
        case let .value(value):
            self.value = value
        }
    }
}

private enum ContainerDriverOwnerEffect: Sendable {
    case unused
}

@Observable
private final class ContainerDriverModel: WebInspectorPersistentModel {
    typealias ID = ContainerDriverModelID
    typealias QueryValue = ContainerDriverQueryValue

    nonisolated let id: ID
    private(set) var value: Int
    private(set) var isInvalidated = false

    init(id: ID, record: ContainerDriverRecord) {
        self.id = id
        value = record.value
    }

    func replace(with record: ContainerDriverRecord) {
        value = record.value
    }

    func apply(_ patch: ContainerDriverRecord.Patch) {
        switch patch {
        case let .value(value):
            self.value = value
        }
    }

    func invalidate() {
        isInvalidated = true
    }
}

private func containerDriverSchemaRegistry(
    didApplyValue: @escaping @Sendable (Int) -> Void
) -> WebInspectorModelSchemaRegistry {
    let id = ContainerDriverModelID(rawValue: 1)
    let schema = WebInspectorModelSchema<ContainerDriverModel>(
        snapshot: { snapshot in
            let value = snapshot.binding == nil ? 0 : 1
            return WebInspectorModelSchemaSnapshot<
                ContainerDriverModel,
                ContainerDriverRecord,
                ContainerDriverOwnerEffect
            >(
                entries: [
                    WebInspectorModelSchemaSnapshotEntry(
                        id: id,
                        record: ContainerDriverRecord(value: value),
                        queryValue: ContainerDriverQueryValue(
                            id: id,
                            value: value
                        ),
                        canonicalRank: .init(rawValue: 0)
                    )
                ]
            )
        },
        delta: { _, records in
            let value = (records.record(for: id)?.value ?? 0) + 1
            return WebInspectorModelSchemaDelta<
                ContainerDriverModel,
                ContainerDriverRecord,
                ContainerDriverOwnerEffect
            >(
                changes: [
                    .update(
                        id: id,
                        patches: WebInspectorModelRecordPatchBatch([
                            .value(value)
                        ]),
                        queryValue: ContainerDriverQueryValue(
                            id: id,
                            value: value
                        ),
                        canonicalRank: .init(rawValue: 0)
                    )
                ]
            )
        },
        makeModel: { _, id, record in
            ContainerDriverModel(id: id, record: record)
        },
        replaceModel: { _, model, record in
            model.replace(with: record)
            didApplyValue(record.value)
        },
        applyPatch: { _, model, patch in
            model.apply(patch)
            didApplyValue(model.value)
        },
        invalidateModel: { _, model in
            model.invalidate()
        },
        applyOwnerEffect: { _, effect, _ in
            switch effect {
            case .unused:
                return
            }
        },
        resetOwnerProjection: { _, _ in }
    )
    return WebInspectorModelSchemaRegistry([
        WebInspectorModelSchemaRegistration(schema)
    ])
}

private actor ModelContainerContextOwner {
    private var context: WebInspectorModelContext?

    func createContext(from container: WebInspectorModelContainer) async throws {
        context = try await container.makeContext(isolation: self)
    }

    func appliedRevision() -> UInt64? {
        context?.appliedContainerRevisionForTesting
    }

    func state() -> WebInspectorModelContext.State? {
        context?.state
    }

    func closeContext() async {
        await context?.close()
    }

    func releaseContext() {
        context = nil
    }
}

@MainActor
@Test
func modelContainerMainContextIsStableAndClosesWithItsContainer() async {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )

    let first = container.mainContext
    let second = container.mainContext

    #expect(first === second)
    await expectEventually {
        first.appliedContainerRevisionForTesting == 0
    }
    #expect(await container.core.metrics.activeContextRegistrationCount == 1)

    await container.close()

    #expect(first.state == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func modelContainerCreatesIndependentActorConfinedContexts() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let firstOwner = ModelContainerContextOwner()
    let secondOwner = ModelContainerContextOwner()

    try await firstOwner.createContext(from: container)
    try await secondOwner.createContext(from: container)

    #expect(await firstOwner.appliedRevision() == 0)
    #expect(await secondOwner.appliedRevision() == 0)
    #expect(await container.core.metrics.activeContextRegistrationCount == 2)

    await firstOwner.closeContext()
    #expect(await firstOwner.state() == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 1)

    await container.close()
    #expect(await secondOwner.state() == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func modelContainerContextAppliesSchemaPayloadBeforeAcknowledgingRevision() async throws {
    let appliedValues = Mutex<[Int]>([])
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: containerDriverSchemaRegistry { value in
            appliedValues.withLock { $0.append(value) }
        }
    )
    let context = WebInspectorModelContext.mainContext(
        for: core,
        isolation: MainActor.shared
    )
    await expectEventually {
        context.appliedContainerRevisionForTesting == 0
    }
    let models = try await context.fetch(
        WebInspectorFetchDescriptor<ContainerDriverModel>()
    )
    let model = try #require(models.first)
    #expect(models.count == 1)
    #expect(model.value == 0)

    let commit = try #require(
        try await core.reduce(
            .reset(WebInspectorPage.Generation(rawValue: 1)),
            attachmentGeneration: .init(rawValue: 1)
        )
    )
    let barrier = try await core.makeAcknowledgementBarrier(
        through: commit.toRevision
    )
    try await core.waitForAcknowledgements(barrier)

    #expect(model.value == 1)
    #expect(appliedValues.withLock { $0 } == [1])
    #expect(context.appliedContainerRevisionForTesting == commit.toRevision)

    await context.close()
    #expect(model.isInvalidated)
}

@MainActor
@Test
func modelContainerRejectsCustomContextCreationAfterClose() async {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let owner = ModelContainerContextOwner()

    await container.close()

    await #expect(throws: WebInspectorModelContainer.Failure.closed) {
        try await owner.createContext(from: container)
    }
}

@MainActor
@Test
func lateMainContextUsesCurrentSnapshotAsItsInitialSchemaState() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: containerDriverSchemaRegistry { _ in }
    )
    let commit = try #require(
        try await core.reduce(
            .reset(WebInspectorPage.Generation(rawValue: 1)),
            attachmentGeneration: .init(rawValue: 1)
        )
    )

    let context = WebInspectorModelContext.mainContext(
        for: core,
        isolation: MainActor.shared
    )
    await expectEventually {
        context.appliedContainerRevisionForTesting == commit.toRevision
    }
    let models = try await context.fetch(
        WebInspectorFetchDescriptor<ContainerDriverModel>()
    )
    #expect(models.map(\.value) == [1])

    await context.close()
}

@MainActor
@Test
func firstMainContextAccessAfterCloseReturnsOneClosedContext() async {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )

    await container.close()

    let first = container.mainContext
    let second = container.mainContext
    #expect(first === second)
    #expect(first.state == .closed)
    await #expect(throws: WebInspectorModelContextQueryError.closed) {
        _ = try await first.fetchIdentifiers(
            WebInspectorFetchDescriptor<ContainerDriverModel>()
        )
    }
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func mainContextMaterializedBetweenCoreClosePhasesDoesNotUnregisterItsReservation() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [],
        modelSchemaRegistry: containerDriverSchemaRegistry { _ in }
    )
    let close = await core.beginClose()

    let context = WebInspectorModelContext.mainContext(
        for: core,
        isolation: MainActor.shared
    )
    try await context.waitUntilContainerReady()
    #expect(context.state == .closed)

    try await core.finishClose(close)
    #expect(await core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func releasedCustomContextUnregistersItsSubscription() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let owner = ModelContainerContextOwner()

    try await owner.createContext(from: container)
    #expect(await container.core.metrics.activeContextRegistrationCount == 1)

    await owner.releaseContext()
    for _ in 0..<1_000 {
        if await container.core.metrics.activeContextRegistrationCount == 0 {
            break
        }
        await Task.yield()
    }
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)

    await container.close()
}

@MainActor
@Test
func canonicalNetworkClearReturnsAfterTwoActiveContextsApplyTheDeletion() async throws {
    let core = WebInspectorModelContainerCore(
        configuredDomains: [.network],
        modelSchemaRegistry: WebInspectorModelSchemaRegistry(
            WebInspectorNetworkModelSchemas.registrations
        )
    )
    let firstContext = WebInspectorModelContext.mainContext(
        for: core,
        isolation: MainActor.shared
    )
    let secondRegistration = try await core.registerContext()
    let secondContextCandidate = WebInspectorModelContext.customContext(
        for: core,
        registration: secondRegistration,
        isolation: MainActor.shared
    )
    let secondContext = try #require(secondContextCandidate)
    try await firstContext.waitUntilContainerReady()
    try await secondContext.waitUntilContainerReady()

    let attachment = WebInspectorContainerAttachmentGeneration(rawValue: 1)
    let generation = WebInspectorPage.Generation(rawValue: 1)
    let page = ModelTarget(
        id: WebInspectorTarget.ID("page"),
        kind: .page,
        frameID: FrameID("main-frame"),
        parentFrameID: nil
    )
    _ = try await core.reduce(
        .reset(generation),
        attachmentGeneration: attachment
    )
    _ = try await core.reduce(
        .targetSnapshot(
            generation: generation,
            through: 0,
            snapshot: ModelTargetSnapshot(
                currentPageID: page.id,
                targets: [
                    ModelTargetState(
                        target: page,
                        navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                        domBindingEpoch: nil,
                        runtimeBindingEpoch: nil,
                        consoleBindingEpoch: nil
                    )
                ]
            )
        ),
        attachmentGeneration: attachment
    )
    let insertion = try #require(
        try await core.reduce(
            .event(
                sequence: 1,
                scope: ModelEventScope(
                    generation: generation,
                    target: page,
                    agentTarget: page,
                    navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                    domBindingEpoch: nil,
                    runtimeBindingEpoch: nil,
                    consoleBindingEpoch: nil
                ),
                payload: .network(
                    canonicalRequestWillBeSent(
                        id: "shared",
                        url: "https://example.test/shared",
                        timestamp: 1
                    )
                )
            ),
            attachmentGeneration: attachment
        )
    )
    let insertionBarrier = try await core.makeAcknowledgementBarrier(
        through: insertion.toRevision
    )
    try await core.waitForAcknowledgements(insertionBarrier)

    let firstController = try await WebInspectorFetchedResultsController<
        NetworkEntry,
        Never
    >(modelContext: firstContext, isolation: MainActor.shared)
    let secondController = try await WebInspectorFetchedResultsController<
        NetworkEntry,
        Never
    >(modelContext: secondContext, isolation: MainActor.shared)
    let firstEntryID = try #require(firstController.snapshot.itemIDs.first)
    let secondEntryID = try #require(secondController.snapshot.itemIDs.first)
    #expect(firstEntryID == secondEntryID)
    let firstEntry = try #require(firstContext.model(for: firstEntryID))
    let secondEntry = try #require(secondContext.model(for: secondEntryID))

    try await firstContext.clearNetworkRequests()

    let clearedRevision = await core.currentRevision
    #expect(firstContext.appliedContainerRevisionForTesting == clearedRevision)
    #expect(secondContext.appliedContainerRevisionForTesting == clearedRevision)
    #expect(firstController.snapshot.itemIDs.isEmpty)
    #expect(secondController.snapshot.itemIDs.isEmpty)
    #expect(firstEntry.isInvalidated)
    #expect(secondEntry.isInvalidated)

    await firstController.close()
    await secondController.close()
    await firstContext.close()
    await secondContext.close()
}

@MainActor
private func expectEventually(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("The expected context state was not committed.", sourceLocation: sourceLocation)
}

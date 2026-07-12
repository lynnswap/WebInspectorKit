import Foundation
import Observation
import Synchronization
import Testing
@testable import WebInspectorDataKit

@MainActor
@Test
func modelContextMaterializesAndReusesItsOwnSchemaModels() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await applyContextSchemaInitial(to: context)

    let id = SchemaPrimaryID(rawValue: 1)
    #expect(context.registeredModel(for: id) == nil)
    let first = try #require(context.model(for: id))
    let second = try #require(context.model(for: id))
    let registered = try #require(context.registeredModel(for: id))
    #expect(first === second)
    #expect(first === registered)
    #expect(first.value == 10)
    #expect(fixture.probe.makeCount == 1)

    await context.close()
    #expect(first.isInvalidated)
    #expect(context.registeredModel(for: id) == nil)
    #expect(context.model(for: id) == nil)
}

@MainActor
@Test
func modelContextsUseEqualIDsAndDistinctSchemaModelInstances() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let registry = fixture.registry
    let firstContext = WebInspectorModelContext(
        modelSchemaRegistry: registry,
        isolation: MainActor.shared
    )
    let secondContext = WebInspectorModelContext(
        modelSchemaRegistry: registry,
        isolation: MainActor.shared
    )
    try await applyContextSchemaInitial(to: firstContext)
    try await applyContextSchemaInitial(to: secondContext)

    let id = SchemaPrimaryID(rawValue: 1)
    let first = try #require(firstContext.model(for: id))
    let second = try #require(secondContext.model(for: id))
    #expect(first.id == second.id)
    #expect(first !== second)
    #expect(fixture.probe.contextIdentityCount == 2)

    await firstContext.close()
    #expect(first.isInvalidated)
    #expect(second.isInvalidated == false)
    await secondContext.close()
    #expect(second.isInvalidated)
}

@Test
func modelContextSchemaGraphRunsOnACustomActor() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let owner = SchemaContextOwnerActor()
    #expect(try await owner.materializes(registry: fixture.registry))
}

@MainActor
@Test
func modelContextOneShotFetchEvaluatesIDsBeforeMaterializingModels() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(
        primary: [1: 10, 2: 20, 3: 30, 4: 40],
        secondary: [:]
    )
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await applyContextSchemaInitial(to: context)
    var descriptor = WebInspectorFetchDescriptor<SchemaPrimaryModel>(
        predicate: #Predicate { $0.value >= 20 },
        sortBy: [SortDescriptor(\.value, order: .reverse)]
    )
    descriptor.fetchOffset = 1
    descriptor.fetchLimit = 2

    let ids = try await context.fetchIdentifiers(descriptor)
    #expect(ids == [.init(rawValue: 3), .init(rawValue: 2)])
    #expect(fixture.probe.makeCount == 0)
    let models = try await context.fetch(descriptor)
    #expect(models.map(\.id) == ids)
    #expect(models.map(\.value) == [30, 20])
    #expect(fixture.probe.makeCount == 2)
    #expect(
        await context.fetchedResultsQueryCore.registrationCountForTesting(
            SchemaPrimaryModel.self
        ) == 0
    )
    await context.close()
}

@MainActor
@Test
func oneShotFetchClaimQueuesDeleteUntilOwnerMaterializationCompletes() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10, 2: 20], secondary: [:])
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await applyContextSchemaInitial(to: context)
    let core = context.fetchedResultsQueryCore
    let claim = try await core.prepareModelFetch(
        SchemaPrimaryModel.self,
        fetchDescriptor: .init()
    )
    fixture.source.setDelta(primary: [.delete(id: 1)])
    let sourceTransaction = context.modelSchemaContextCore.changes(
        at: 1,
        transaction: .init()
    )
    let source = Task {
        try await sourceTransaction.stage(on: core)
    }
    #expect(await core.hasOutstandingModelFetchAdmissionForTesting())

    let fetched = claim.ids.map { id -> SchemaPrimaryModel in
        guard let model = context.model(for: id) else {
            preconditionFailure("A claimed fetch ID must remain materializable.")
        }
        return model
    }
    #expect(fetched.map(\.id) == [.init(rawValue: 1), .init(rawValue: 2)])
    #expect(fetched.allSatisfy { $0.isInvalidated == false })
    #expect(await claim.complete() == .activated)

    let sourceCommit = try await source.value
    #expect(context.publish(sourceCommit))
    #expect(fetched[0].isInvalidated)
    #expect(fetched[1].isInvalidated == false)
    #expect(context.model(for: SchemaPrimaryID(rawValue: 1)) == nil)
    await context.close()
}

@MainActor
@Test
func unsupportedOneShotFetchFailsWithoutCreatingAQueryEngine() async throws {
    let context = WebInspectorModelContext()
    let descriptor = WebInspectorFetchDescriptor<SchemaPrimaryModel>()
    await #expect(throws: WebInspectorModelContextQueryError.unsupportedModel) {
        _ = try await context.fetchIdentifiers(descriptor)
    }
    await #expect(throws: WebInspectorModelContextQueryError.unsupportedModel) {
        _ = try await context.fetch(descriptor)
    }
    #expect(await context.fetchedResultsQueryCore.queryEngineCountForTesting() == 0)
    await context.close()
}

@MainActor
@Test
func contextCloseAbandonsAPendingOneShotFetchClaim() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await applyContextSchemaInitial(to: context)
    let core = context.fetchedResultsQueryCore
    let claim = try await core.prepareModelFetch(
        SchemaPrimaryModel.self,
        fetchDescriptor: .init()
    )
    await context.close()
    #expect(claim.wasAbandoned)
    await claim.abandon()
    #expect(await core.hasOutstandingModelFetchAdmissionForTesting() == false)
}

@MainActor
@Test
func deinitializedOneShotFetchClaimUnblocksQueuedSourceWork() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let context = WebInspectorModelContext(
        modelSchemaRegistry: fixture.registry,
        isolation: MainActor.shared
    )
    try await applyContextSchemaInitial(to: context)
    let core = context.fetchedResultsQueryCore
    var claim: WebInspectorModelFetchClaim<SchemaPrimaryModel>? =
        try await core.prepareModelFetch(
            SchemaPrimaryModel.self,
            fetchDescriptor: .init()
        )
    fixture.source.setDelta(primary: [.set(id: 1, value: 11)])
    let sourceTransaction = context.modelSchemaContextCore.changes(
        at: 1,
        transaction: .init()
    )
    let source = Task {
        try await sourceTransaction.stage(on: core)
    }
    #expect(claim?.ids == [.init(rawValue: 1)])
    claim = nil

    let sourceCommit = try await source.value
    #expect(context.publish(sourceCommit))
    #expect(await core.hasOutstandingModelFetchAdmissionForTesting() == false)
    let ids = try await context.fetchIdentifiers(
        WebInspectorFetchDescriptor<SchemaPrimaryModel>()
    )
    #expect(ids == [.init(rawValue: 1)])
    await context.close()
}

@MainActor
@Test
func schemaCommitPatchesModelThenFetchedResultsBackingBeforePublication() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let context = WebInspectorModelContext(
        configuredFetchedResultsModelTypes: [
            SchemaPrimaryModel.self,
            SchemaSecondaryModel.self,
        ],
        isolation: MainActor.shared
    )
    let schemas = fixture.registry.makeContext(owner: context)
    let initial = try await schemas.core.initial(
        at: 0,
        snapshot: emptySchemaCanonicalSnapshot()
    ).stage(on: context.fetchedResultsQueryCore)
    #expect(initial.publish(on: schemas.owner, owner: context))

    let model: SchemaPrimaryModel = try #require(
        schemas.owner.model(
            for: SchemaPrimaryID(rawValue: 1),
            owner: context
        )
    )
    let controller = try await WebInspectorFetchedResultsController<
        SchemaPrimaryModel,
        Never
    >(
        modelContext: context,
        isolation: MainActor.shared
    )
    var iterator = controller.updates().makeAsyncIterator()
    _ = try await iterator.next()

    fixture.source.setDelta(primary: [.set(id: 1, value: 11)])
    let change = try await schemas.core.changes(
        at: 1,
        transaction: .init()
    ).stage(on: context.fetchedResultsQueryCore)
    #expect(model.value == 10)
    #expect(controller.revision == 0)
    #expect(change.publish(on: schemas.owner, owner: context))
    #expect(model.value == 11)
    #expect(controller.revision == 1)
    #expect(controller.publicationRevisionForTesting == 1)
    guard case let .changes(from, to, _, _, updatedIDs) = try await iterator.next() else {
        Issue.record("Expected one schema-backed controller update.")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(updatedIDs == [.init(rawValue: 1)])

    await controller.close()
    schemas.core.close().apply(on: schemas.owner, owner: context)
    await context.close()
}

@Test
func schemaRegistryPreservesSameContextIdentityWithoutEagerMaterialization() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(
        primary: [1: 10],
        secondary: [1: 100]
    )
    let harness = SchemaTestHarness(registry: fixture.registry)

    try await harness.applyInitial(revision: 0)
    #expect(await harness.registeredPrimary(1) == nil)
    #expect(fixture.probe.makeCount == 0)

    let first = try #require(await harness.primary(1))
    let second = try #require(await harness.primary(1))
    #expect(first.identity == second.identity)
    #expect(first.value == 10)
    #expect(fixture.probe.makeCount == 1)
}

@Test
func schemaRegistryCreatesDistinctIdentityGraphsForDifferentContexts() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let registry = fixture.registry
    let firstHarness = SchemaTestHarness(registry: registry)
    let secondHarness = SchemaTestHarness(registry: registry)

    try await firstHarness.applyInitial(revision: 0)
    try await secondHarness.applyInitial(revision: 0)
    let first = try #require(await firstHarness.primary(1))
    let second = try #require(await secondHarness.primary(1))

    #expect(first.identity != second.identity)
    #expect(fixture.probe.contextIdentityCount == 2)
}

@Test
func schemaOwnerRegistryDoesNotRetainItsContextOwner() {
    let fixture = SchemaTestFixture()
    weak var weakOwner: WebInspectorModelContext?
    var schemas: WebInspectorModelSchemaContext?

    do {
        let owner = WebInspectorModelContext()
        weakOwner = owner
        schemas = fixture.registry.makeContext(owner: owner)
    }

    withExtendedLifetime(schemas) {
        #expect(weakOwner == nil)
    }
}

@Test
func unclaimedSchemaUpdateDoesNoModelOwnerWork() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    fixture.probe.clearEvents()

    fixture.source.setDelta(primary: [.set(id: 1, value: 11)])
    try await harness.applyChanges(revision: 1)

    #expect(fixture.probe.events.isEmpty)
    #expect(await harness.registeredPrimary(1) == nil)
    #expect(try #require(await harness.primary(1)).value == 11)
}

@Test
func claimedSchemaUpdateAndDeleteMutateTheSameModelInPlace() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    let initial = try #require(await harness.primary(1))
    fixture.probe.clearEvents()

    fixture.source.setDelta(primary: [.set(id: 1, value: 11)])
    try await harness.applyChanges(revision: 1)
    let updated = try #require(await harness.primary(1))
    #expect(updated.identity == initial.identity)
    #expect(updated.value == 11)
    #expect(fixture.probe.events == [.patch("primary", id: 1, .set(11))])

    fixture.probe.clearEvents()
    fixture.source.setDelta(primary: [.delete(id: 1)])
    try await harness.applyChanges(revision: 2)
    #expect(await harness.registeredPrimary(1) == nil)
    #expect(fixture.probe.events == [.invalidate("primary", id: 1)])
}

@Test
func schemaCoalescesOrderedPatchesUsesLastQueryProjectionAndAppliesEffectsFirst() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    _ = try #require(await harness.primary(1))
    fixture.probe.clearEvents()

    fixture.source.setDelta(
        primary: [
            .increment(id: 1, amount: 2, authoritativeQueryValue: 12),
            .increment(id: 1, amount: 3, authoritativeQueryValue: 15),
        ],
        primaryEffects: ["topology"]
    )
    try await harness.applyChanges(revision: 1)

    #expect(try #require(await harness.primary(1)).value == 15)
    #expect(
        try await harness.primaryIDs(matching: 15)
            == [SchemaPrimaryID(rawValue: 1)]
    )
    #expect(try await harness.primaryIDs(matching: 12).isEmpty)
    #expect(
        fixture.probe.events == [
            .effect("primary", "topology"),
            .patch("primary", id: 1, .increment(2)),
            .patch("primary", id: 1, .increment(3)),
        ]
    )
}

@Test
func schemaOwnerModelViewReadsOnlyAlreadyMaterializedIdentityGraph() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10, 2: 20], secondary: [:])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    _ = try #require(await harness.primary(1))
    #expect(fixture.probe.makeCount == 1)

    fixture.source.setDelta(primaryEffects: ["inspect-owner-models"])
    try await harness.applyChanges(revision: 1)

    #expect(fixture.probe.makeCount == 1)
    #expect(
        fixture.probe.ownerModelObservations == [
            SchemaOwnerModelObservation(
                firstLookupValue: 10,
                secondLookupValue: nil,
                visitedValues: [10]
            )
        ]
    )
}

@Test
func schemaInitialAndResetRebuildTransientOwnerProjectionInPhaseOrder() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(
        primary: [1: 10, 2: 20],
        secondary: [1: 100],
        primaryEffects: ["primary-root"],
        secondaryEffects: ["secondary-root"]
    )
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    #expect(
        fixture.probe.events == [
            .effect("primary", "primary-root"),
            .effect("secondary", "secondary-root"),
        ]
    )
    _ = try #require(await harness.primary(1))
    _ = try #require(await harness.primary(2))
    _ = try #require(await harness.secondary(1))
    fixture.probe.clearEvents()

    fixture.source.setSnapshot(
        primary: [1: 11],
        secondary: [1: 101],
        primaryEffects: ["new-primary-root"],
        secondaryEffects: ["new-secondary-root"]
    )
    try await harness.applyReset(revision: 8)

    let resetEvents = fixture.probe.events
    #expect(
        Array(resetEvents.prefix(4)) == [
            .resetProjection("primary"),
            .effect("primary", "new-primary-root"),
            .resetProjection("secondary"),
            .effect("secondary", "new-secondary-root"),
        ]
    )
    #expect(
        Array(resetEvents[4..<6]).contains(
            .replace("primary", id: 1, value: 11)
        )
    )
    #expect(
        Array(resetEvents[4..<6]).contains(
            .invalidate("primary", id: 2)
        )
    )
    #expect(resetEvents[6] == .replace("secondary", id: 1, value: 101))
}

@Test
func canonicalResetSnapshotSubsumesCoexistingDeltaEffects() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    _ = try #require(await harness.primary(1))
    fixture.probe.clearEvents()

    fixture.source.setSnapshot(
        primary: [1: 12],
        secondary: [:],
        primaryEffects: ["replacement-topology"]
    )
    fixture.source.setDelta(
        primary: [.set(id: 1, value: 999)],
        primaryEffects: ["must-not-survive-reset"]
    )
    var transaction = WebInspectorCanonicalModelTransaction()
    transaction.resetSnapshot = emptySchemaCanonicalSnapshot()
    try await harness.applyChanges(revision: 1, transaction: transaction)

    #expect(try #require(await harness.primary(1)).value == 12)
    #expect(
        fixture.probe.events == [
            .resetProjection("primary"),
            .effect("primary", "replacement-topology"),
            .resetProjection("secondary"),
            .replace("primary", id: 1, value: 12),
        ]
    )
}

@Test
func emptySchemaBatchesAdvanceEveryConfiguredModelRevision() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [1: 100])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)

    fixture.source.setDelta()
    try await harness.applyChanges(revision: 1)
    fixture.source.setDelta(
        primary: [.set(id: 1, value: 11)],
        secondary: [.set(id: 1, value: 101)]
    )
    try await harness.applyChanges(revision: 2)

    #expect(try #require(await harness.primary(1)).value == 11)
    #expect(try #require(await harness.secondary(1)).value == 101)
}

@Test
func emptySchemaRegistryAdvancesInitialDeltaAndResetThroughCombinedCommits() async throws {
    let owner = WebInspectorModelContext()
    let schemas = WebInspectorModelSchemaRegistry([]).makeContext(owner: owner)
    let queryCore = WebInspectorModelContextCore()

    let initial = try await schemas.core.initial(
        at: 0,
        snapshot: emptySchemaCanonicalSnapshot()
    ).stage(on: queryCore)
    #expect(initial.canonicalRevision == 0)
    #expect(initial.publish(on: schemas.owner, owner: owner))

    let delta = try await schemas.core.changes(
        at: 1,
        transaction: .init()
    ).stage(on: queryCore)
    #expect(delta.canonicalRevision == 1)
    #expect(delta.publish(on: schemas.owner, owner: owner))

    let reset = try await schemas.core.reset(
        at: 8,
        snapshot: emptySchemaCanonicalSnapshot()
    ).stage(on: queryCore)
    #expect(reset.canonicalRevision == 8)
    #expect(reset.publish(on: schemas.owner, owner: owner))

    schemas.core.close().apply(on: schemas.owner, owner: owner)
    await queryCore.close()
}

@Test
func schemaCloseResetsAllOwnerProjectionsBeforeInvalidatingModels() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [1: 100])
    let harness = SchemaTestHarness(registry: fixture.registry)
    try await harness.applyInitial(revision: 0)
    _ = try #require(await harness.primary(1))
    _ = try #require(await harness.secondary(1))
    fixture.probe.clearEvents()

    await harness.close()

    #expect(
        fixture.probe.events == [
            .resetProjection("primary"),
            .resetProjection("secondary"),
            .invalidate("primary", id: 1),
            .invalidate("secondary", id: 1),
        ]
    )
}

@Test
func schemaRegistryRunsOnACustomActorWithoutMainActorOwnership() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
    let harness = SchemaTestHarness(registry: fixture.registry)

    try await harness.applyInitial(revision: 0)
    #expect(await harness.isOnOwnerActor())
    #expect(try #require(await harness.primary(1)).value == 10)
}

@Test
func schemaTransactionStageIsOneShot() async {
    await #expect(processExitsWith: .failure) {
        let fixture = SchemaTestFixture()
        fixture.source.setSnapshot(primary: [:], secondary: [:])
        let owner = WebInspectorModelContext()
        let schemas = fixture.registry.makeContext(owner: owner)
        let transaction = schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        let queryCore = WebInspectorModelContextCore()
        _ = try await transaction.stage(on: queryCore)
        _ = try await transaction.stage(on: queryCore)
    }
}

@Test
func schemaCoreRejectsRepeatedInitialPreparation() async {
    await #expect(processExitsWith: .failure) {
        let owner = WebInspectorModelContext()
        let schemas = WebInspectorModelSchemaRegistry([]).makeContext(owner: owner)
        _ = schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        _ = schemas.core.initial(
            at: 1,
            snapshot: emptySchemaCanonicalSnapshot()
        )
    }
}

@Test
func schemaCoreRejectsLaterRevisionWhileInitialIsOutstanding() async {
    await #expect(processExitsWith: .failure) {
        let owner = WebInspectorModelContext()
        let schemas = WebInspectorModelSchemaRegistry([]).makeContext(owner: owner)
        _ = schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        _ = schemas.core.changes(
            at: 1,
            transaction: .init()
        )
    }
}

@Test
func schemaCoreRejectsNextRevisionWhileOneIsOutstanding() async {
    await #expect(processExitsWith: .failure) {
        let owner = WebInspectorModelContext()
        let schemas = WebInspectorModelSchemaRegistry([]).makeContext(owner: owner)
        let queryCore = WebInspectorModelContextCore()
        let initial = try await schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        ).stage(on: queryCore)
        _ = initial.publish(on: schemas.owner, owner: owner)

        _ = schemas.core.changes(
            at: 1,
            transaction: .init()
        )
        _ = schemas.core.reset(
            at: 2,
            snapshot: emptySchemaCanonicalSnapshot()
        )
    }
}

@Test
func schemaCommitRejectsAForeignOwnerRegistry() async {
    await #expect(processExitsWith: .failure) {
        let fixture = SchemaTestFixture()
        fixture.source.setSnapshot(primary: [:], secondary: [:])
        let firstOwner = WebInspectorModelContext()
        let foreignOwner = WebInspectorModelContext()
        let first = fixture.registry.makeContext(owner: firstOwner)
        let queryCore = WebInspectorModelContextCore()
        let transaction = first.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        let commit = try await transaction.stage(on: queryCore)
        _ = commit.publish(
            on: first.owner,
            owner: foreignOwner
        )
    }
}

@Test
func schemaOwnerRegistryRejectsAForeignContextDuringModelLookup() async {
    await #expect(processExitsWith: .failure) {
        let fixture = SchemaTestFixture()
        fixture.source.setSnapshot(primary: [1: 10], secondary: [:])
        let owner = WebInspectorModelContext()
        let schemas = fixture.registry.makeContext(owner: owner)
        let queryCore = WebInspectorModelContextCore()
        let transaction = schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        let commit = try await transaction.stage(on: queryCore)
        _ = commit.publish(on: schemas.owner, owner: owner)
        let _: SchemaPrimaryModel? = schemas.owner.model(
            for: SchemaPrimaryID(rawValue: 1),
            owner: WebInspectorModelContext()
        )
    }
}

@Test
func schemaCoreRejectsCloseWhileACombinedCommitIsOutstanding() async {
    await #expect(processExitsWith: .failure) {
        let fixture = SchemaTestFixture()
        fixture.source.setSnapshot(primary: [:], secondary: [:])
        let owner = WebInspectorModelContext()
        let schemas = fixture.registry.makeContext(owner: owner)
        let queryCore = WebInspectorModelContextCore()
        let transaction = schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        _ = try await transaction.stage(on: queryCore)
        _ = schemas.core.close()
    }
}

@Test
func schemaCoreCanCloseAfterAStagedCommitAborts() async throws {
    let fixture = SchemaTestFixture()
    fixture.source.setSnapshot(primary: [:], secondary: [:])
    let owner = WebInspectorModelContext()
    let schemas = fixture.registry.makeContext(owner: owner)
    let queryCore = WebInspectorModelContextCore()
    let transaction = schemas.core.initial(
        at: 0,
        snapshot: emptySchemaCanonicalSnapshot()
    )
    let commit = try await transaction.stage(on: queryCore)

    #expect(
        await commit.abort(throwing: CancellationError()) == .aborted
    )
    schemas.core.close().apply(on: schemas.owner, owner: owner)
    await queryCore.close()
}

@Test
func schemaCoreCanCloseAfterTransactionStagingFails() async throws {
    let owner = WebInspectorModelContext()
    let schemas = WebInspectorModelSchemaRegistry([]).makeContext(owner: owner)
    let queryCore = WebInspectorModelContextCore()
    await queryCore.close()
    let transaction = schemas.core.initial(
        at: 0,
        snapshot: emptySchemaCanonicalSnapshot()
    )

    await #expect(throws: WebInspectorFetchedResultsQueryError.closedRegistration) {
        _ = try await transaction.stage(on: queryCore)
    }
    schemas.core.close().apply(on: schemas.owner, owner: owner)
}

@Test
func schemaRegistryRejectsDuplicateModelTypes() async {
    await #expect(processExitsWith: .failure) {
        let fixture = SchemaTestFixture()
        let registration = WebInspectorModelSchemaRegistration(
            fixture.primarySchemaForFailureTesting
        )
        _ = WebInspectorModelSchemaRegistry([
            registration,
            registration,
        ])
    }
}

@Test
func schemaSnapshotRejectsDuplicateCanonicalRanks() async {
    await #expect(processExitsWith: .failure) {
        let schema = WebInspectorModelSchema<SchemaPrimaryModel>(
            snapshot: { _ in
                WebInspectorModelSchemaSnapshot<
                    SchemaPrimaryModel,
                    SchemaTestRecord,
                    SchemaNoEffect
                >(
                    entries: [
                        WebInspectorModelSchemaSnapshotEntry(
                            id: SchemaPrimaryID(rawValue: 1),
                            record: SchemaTestRecord(value: 1),
                            queryValue: SchemaPrimaryQueryValue(
                                id: SchemaPrimaryID(rawValue: 1),
                                value: 1
                            ),
                            canonicalRank: .init(rawValue: 0)
                        ),
                        WebInspectorModelSchemaSnapshotEntry(
                            id: SchemaPrimaryID(rawValue: 2),
                            record: SchemaTestRecord(value: 2),
                            queryValue: SchemaPrimaryQueryValue(
                                id: SchemaPrimaryID(rawValue: 2),
                                value: 2
                            ),
                            canonicalRank: .init(rawValue: 0)
                        ),
                    ]
                )
            },
            delta: { _, _ in
                WebInspectorModelSchemaDelta<
                    SchemaPrimaryModel,
                    SchemaTestRecord,
                    SchemaNoEffect
                >(changes: [])
            },
            makeModel: { _, id, record in
                SchemaPrimaryModel(id: id, value: record.value)
            },
            replaceModel: { _, model, record in
                model.value = record.value
            },
            applyPatch: { _, model, patch in
                patch.apply(to: &model.value)
            },
            invalidateModel: { _, model in
                model.isInvalidated = true
            },
            applyOwnerEffect: { _, _, _ in },
            resetOwnerProjection: { _, _ in }
        )
        let owner = WebInspectorModelContext()
        let schemas = WebInspectorModelSchemaRegistry([
            WebInspectorModelSchemaRegistration(schema)
        ]).makeContext(owner: owner)
        _ = schemas.core.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
    }
}

private struct SchemaPrimaryID: WebInspectorPersistentIdentifier {
    typealias Model = SchemaPrimaryModel
    let rawValue: Int
}

private struct SchemaPrimaryQueryValue: Identifiable, Sendable {
    let id: SchemaPrimaryID
    let value: Int
}

@Observable
private final class SchemaPrimaryModel: WebInspectorPersistentModel {
    typealias ID = SchemaPrimaryID
    typealias QueryValue = SchemaPrimaryQueryValue

    nonisolated let id: SchemaPrimaryID
    var value: Int
    var isInvalidated = false

    init(id: SchemaPrimaryID, value: Int) {
        self.id = id
        self.value = value
    }
}

private struct SchemaSecondaryID: WebInspectorPersistentIdentifier {
    typealias Model = SchemaSecondaryModel
    let rawValue: Int
}

private struct SchemaSecondaryQueryValue: Identifiable, Sendable {
    let id: SchemaSecondaryID
    let value: Int
}

@Observable
private final class SchemaSecondaryModel: WebInspectorPersistentModel {
    typealias ID = SchemaSecondaryID
    typealias QueryValue = SchemaSecondaryQueryValue

    nonisolated let id: SchemaSecondaryID
    var value: Int
    var isInvalidated = false

    init(id: SchemaSecondaryID, value: Int) {
        self.id = id
        self.value = value
    }
}

private enum SchemaTestRecordPatch: Equatable, Sendable {
    case set(Int)
    case increment(Int)

    func apply(to value: inout Int) {
        switch self {
        case let .set(replacement):
            value = replacement
        case let .increment(amount):
            value += amount
        }
    }
}

private struct SchemaTestRecord: Equatable, WebInspectorModelRecord {
    var value: Int

    mutating func apply(_ patch: SchemaTestRecordPatch) {
        patch.apply(to: &value)
    }
}

private enum SchemaNoEffect: Sendable {
    case unused
}

private enum SchemaTestPatch: Sendable {
    case update(
        id: Int,
        patch: SchemaTestRecordPatch,
        authoritativeQueryValue: Int?
    )
    case delete(id: Int)

    static func set(id: Int, value: Int) -> Self {
        .update(
            id: id,
            patch: .set(value),
            authoritativeQueryValue: value
        )
    }

    static func increment(
        id: Int,
        amount: Int,
        authoritativeQueryValue: Int?
    ) -> Self {
        .update(
            id: id,
            patch: .increment(amount),
            authoritativeQueryValue: authoritativeQueryValue
        )
    }
}

private final class SchemaTestSource: Sendable {
    private struct State: Sendable {
        var primarySnapshot: [Int: Int] = [:]
        var secondarySnapshot: [Int: Int] = [:]
        var primarySnapshotEffects: [String] = []
        var secondarySnapshotEffects: [String] = []
        var primaryDelta: [SchemaTestPatch] = []
        var secondaryDelta: [SchemaTestPatch] = []
        var primaryDeltaEffects: [String] = []
        var secondaryDeltaEffects: [String] = []
    }

    private let state = Mutex(State())

    func setSnapshot(
        primary: [Int: Int],
        secondary: [Int: Int],
        primaryEffects: [String] = [],
        secondaryEffects: [String] = []
    ) {
        state.withLock { state in
            state.primarySnapshot = primary
            state.secondarySnapshot = secondary
            state.primarySnapshotEffects = primaryEffects
            state.secondarySnapshotEffects = secondaryEffects
        }
    }

    func setDelta(
        primary: [SchemaTestPatch] = [],
        secondary: [SchemaTestPatch] = [],
        primaryEffects: [String] = [],
        secondaryEffects: [String] = []
    ) {
        state.withLock { state in
            state.primaryDelta = primary
            state.secondaryDelta = secondary
            state.primaryDeltaEffects = primaryEffects
            state.secondaryDeltaEffects = secondaryEffects
        }
    }

    func primarySnapshot() -> ([Int: Int], [String]) {
        state.withLock { ($0.primarySnapshot, $0.primarySnapshotEffects) }
    }

    func secondarySnapshot() -> ([Int: Int], [String]) {
        state.withLock { ($0.secondarySnapshot, $0.secondarySnapshotEffects) }
    }

    func primaryDelta() -> ([SchemaTestPatch], [String]) {
        state.withLock { ($0.primaryDelta, $0.primaryDeltaEffects) }
    }

    func secondaryDelta() -> ([SchemaTestPatch], [String]) {
        state.withLock { ($0.secondaryDelta, $0.secondaryDeltaEffects) }
    }
}

private enum SchemaTestOwnerEvent: Equatable, Sendable {
    case make(String, id: Int, value: Int)
    case effect(String, String)
    case resetProjection(String)
    case replace(String, id: Int, value: Int)
    case patch(String, id: Int, SchemaTestRecordPatch)
    case invalidate(String, id: Int)
}

private struct SchemaOwnerModelObservation: Equatable, Sendable {
    let firstLookupValue: Int?
    let secondLookupValue: Int?
    let visitedValues: [Int]
}

private final class SchemaTestProbe: Sendable {
    private struct State: Sendable {
        var events: [SchemaTestOwnerEvent] = []
        var contextIdentities: Set<ObjectIdentifier> = []
        var ownerModelObservations: [SchemaOwnerModelObservation] = []
    }

    private let state = Mutex(State())

    var events: [SchemaTestOwnerEvent] {
        state.withLock(\.events)
    }

    var makeCount: Int {
        state.withLock { state in
            state.events.count { event in
                if case .make = event {
                    return true
                }
                return false
            }
        }
    }

    var contextIdentityCount: Int {
        state.withLock { $0.contextIdentities.count }
    }

    var ownerModelObservations: [SchemaOwnerModelObservation] {
        state.withLock(\.ownerModelObservations)
    }

    func record(
        _ event: SchemaTestOwnerEvent,
        context: WebInspectorModelContext
    ) {
        state.withLock { state in
            state.events.append(event)
            state.contextIdentities.insert(ObjectIdentifier(context))
        }
    }

    func clearEvents() {
        state.withLock { $0.events.removeAll(keepingCapacity: true) }
    }

    func recordOwnerModels(
        _ models: borrowing WebInspectorModelSchemaOwnerModels<SchemaPrimaryModel>
    ) {
        var visitedValues: [Int] = []
        models.forEachRegisteredModel { model in
            visitedValues.append(model.value)
        }
        visitedValues.sort()
        let observation = SchemaOwnerModelObservation(
            firstLookupValue: models.model(
                for: SchemaPrimaryID(rawValue: 1)
            )?.value,
            secondLookupValue: models.model(
                for: SchemaPrimaryID(rawValue: 2)
            )?.value,
            visitedValues: visitedValues
        )
        state.withLock { state in
            state.ownerModelObservations.append(observation)
        }
    }
}

private struct SchemaTestFixture {
    let source = SchemaTestSource()
    let probe = SchemaTestProbe()

    var registry: WebInspectorModelSchemaRegistry {
        WebInspectorModelSchemaRegistry([
            WebInspectorModelSchemaRegistration(primarySchema),
            WebInspectorModelSchemaRegistration(secondarySchema),
        ])
    }

    var primarySchemaForFailureTesting: WebInspectorModelSchema<SchemaPrimaryModel> {
        primarySchema
    }

    private var primarySchema: WebInspectorModelSchema<SchemaPrimaryModel> {
        WebInspectorModelSchema(
            snapshot: { [source] _ in
                let (values, effects) = source.primarySnapshot()
                return WebInspectorModelSchemaSnapshot(
                    entries: values.keys.sorted().map { rawID in
                        let id = SchemaPrimaryID(rawValue: rawID)
                        return WebInspectorModelSchemaSnapshotEntry(
                            id: id,
                            record: SchemaTestRecord(value: values[rawID]!),
                            queryValue: SchemaPrimaryQueryValue(
                                id: id,
                                value: values[rawID]!
                            ),
                            canonicalRank: .init(rawValue: UInt64(rawID))
                        )
                    },
                    ownerEffects: effects
                )
            },
            delta: { [source] _, lookup in
                let (sourceChanges, effects) = source.primaryDelta()
                var patchesByID: [Int: [SchemaTestRecordPatch]] = [:]
                var queryValueByID: [Int: Int] = [:]
                var deletedIDs: Set<Int> = []
                for change in sourceChanges {
                    switch change {
                    case let .update(id, patch, authoritativeQueryValue):
                        patchesByID[id, default: []].append(patch)
                        if let authoritativeQueryValue {
                            queryValueByID[id] = authoritativeQueryValue
                        }
                    case let .delete(id):
                        deletedIDs.insert(id)
                    }
                }
                return WebInspectorModelSchemaDelta(
                    changes: Set(patchesByID.keys).union(deletedIDs).sorted().map { rawID in
                        let id = SchemaPrimaryID(rawValue: rawID)
                        if deletedIDs.contains(rawID) {
                            return .delete(id: id)
                        }
                        precondition(lookup.record(for: id) != nil)
                        let patches = WebInspectorModelRecordPatchBatch<SchemaTestRecord>(
                            patchesByID[rawID]!
                        )
                        return .update(
                            id: id,
                            patches: patches,
                            queryValue: queryValueByID[rawID].map {
                                SchemaPrimaryQueryValue(id: id, value: $0)
                            },
                            canonicalRank: queryValueByID[rawID].map { _ in
                                .init(rawValue: UInt64(rawID))
                            }
                        )
                    },
                    ownerEffects: effects
                )
            },
            makeModel: { [probe] context, id, record in
                probe.record(
                    .make("primary", id: id.rawValue, value: record.value),
                    context: context
                )
                return SchemaPrimaryModel(id: id, value: record.value)
            },
            replaceModel: { [probe] context, model, record in
                model.value = record.value
                probe.record(
                    .replace("primary", id: model.id.rawValue, value: record.value),
                    context: context
                )
            },
            applyPatch: { [probe] context, model, patch in
                patch.apply(to: &model.value)
                probe.record(
                    .patch("primary", id: model.id.rawValue, patch),
                    context: context
                )
            },
            invalidateModel: { [probe] context, model in
                model.isInvalidated = true
                probe.record(
                    .invalidate("primary", id: model.id.rawValue),
                    context: context
                )
            },
            applyOwnerEffect: { [probe] context, effect, models in
                probe.recordOwnerModels(models)
                probe.record(.effect("primary", effect), context: context)
            },
            resetOwnerProjection: { [probe] context, _ in
                probe.record(.resetProjection("primary"), context: context)
            }
        )
    }

    private var secondarySchema: WebInspectorModelSchema<SchemaSecondaryModel> {
        WebInspectorModelSchema(
            snapshot: { [source] _ in
                let (values, effects) = source.secondarySnapshot()
                return WebInspectorModelSchemaSnapshot(
                    entries: values.keys.sorted().map { rawID in
                        let id = SchemaSecondaryID(rawValue: rawID)
                        return WebInspectorModelSchemaSnapshotEntry(
                            id: id,
                            record: SchemaTestRecord(value: values[rawID]!),
                            queryValue: SchemaSecondaryQueryValue(
                                id: id,
                                value: values[rawID]!
                            ),
                            canonicalRank: .init(rawValue: UInt64(rawID))
                        )
                    },
                    ownerEffects: effects
                )
            },
            delta: { [source] _, lookup in
                let (sourceChanges, effects) = source.secondaryDelta()
                var patchesByID: [Int: [SchemaTestRecordPatch]] = [:]
                var queryValueByID: [Int: Int] = [:]
                var deletedIDs: Set<Int> = []
                for change in sourceChanges {
                    switch change {
                    case let .update(id, patch, authoritativeQueryValue):
                        patchesByID[id, default: []].append(patch)
                        if let authoritativeQueryValue {
                            queryValueByID[id] = authoritativeQueryValue
                        }
                    case let .delete(id):
                        deletedIDs.insert(id)
                    }
                }
                return WebInspectorModelSchemaDelta(
                    changes: Set(patchesByID.keys).union(deletedIDs).sorted().map { rawID in
                        let id = SchemaSecondaryID(rawValue: rawID)
                        if deletedIDs.contains(rawID) {
                            return .delete(id: id)
                        }
                        precondition(lookup.record(for: id) != nil)
                        let patches = WebInspectorModelRecordPatchBatch<SchemaTestRecord>(
                            patchesByID[rawID]!
                        )
                        return .update(
                            id: id,
                            patches: patches,
                            queryValue: queryValueByID[rawID].map {
                                SchemaSecondaryQueryValue(id: id, value: $0)
                            },
                            canonicalRank: queryValueByID[rawID].map { _ in
                                .init(rawValue: UInt64(rawID))
                            }
                        )
                    },
                    ownerEffects: effects
                )
            },
            makeModel: { [probe] context, id, record in
                probe.record(
                    .make("secondary", id: id.rawValue, value: record.value),
                    context: context
                )
                return SchemaSecondaryModel(id: id, value: record.value)
            },
            replaceModel: { [probe] context, model, record in
                model.value = record.value
                probe.record(
                    .replace("secondary", id: model.id.rawValue, value: record.value),
                    context: context
                )
            },
            applyPatch: { [probe] context, model, patch in
                patch.apply(to: &model.value)
                probe.record(
                    .patch("secondary", id: model.id.rawValue, patch),
                    context: context
                )
            },
            invalidateModel: { [probe] context, model in
                model.isInvalidated = true
                probe.record(
                    .invalidate("secondary", id: model.id.rawValue),
                    context: context
                )
            },
            applyOwnerEffect: { [probe] context, effect, _ in
                probe.record(.effect("secondary", effect), context: context)
            },
            resetOwnerProjection: { [probe] context, _ in
                probe.record(.resetProjection("secondary"), context: context)
            }
        )
    }
}

private actor SchemaTestHarness {
    struct ModelState: Sendable {
        let identity: ObjectIdentifier
        let value: Int
    }

    private let context = WebInspectorModelContext()
    private let schemas: WebInspectorModelSchemaContext
    private let queryCore = WebInspectorModelContextCore()

    init(registry: WebInspectorModelSchemaRegistry) {
        schemas = registry.makeContext(owner: context)
    }

    func applyInitial(revision: UInt64) async throws {
        let transaction = schemas.core.initial(
            at: revision,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        try await publish(transaction)
    }

    func applyReset(revision: UInt64) async throws {
        let transaction = schemas.core.reset(
            at: revision,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        try await publish(transaction)
    }

    func applyChanges(
        revision: UInt64,
        transaction: WebInspectorCanonicalModelTransaction = .init()
    ) async throws {
        try await publish(
            schemas.core.changes(
                at: revision,
                transaction: transaction
            )
        )
    }

    func primary(_ rawID: Int) -> ModelState? {
        guard
            let model: SchemaPrimaryModel = schemas.owner.model(
                for: SchemaPrimaryID(rawValue: rawID),
                owner: context
            )
        else {
            return nil
        }
        return ModelState(
            identity: ObjectIdentifier(model),
            value: model.value
        )
    }

    func secondary(_ rawID: Int) -> ModelState? {
        guard
            let model: SchemaSecondaryModel = schemas.owner.model(
                for: SchemaSecondaryID(rawValue: rawID),
                owner: context
            )
        else {
            return nil
        }
        return ModelState(
            identity: ObjectIdentifier(model),
            value: model.value
        )
    }

    func registeredPrimary(_ rawID: Int) -> ModelState? {
        guard
            let model: SchemaPrimaryModel = schemas.owner.registeredModel(
                for: SchemaPrimaryID(rawValue: rawID),
                owner: context
            )
        else {
            return nil
        }
        return ModelState(
            identity: ObjectIdentifier(model),
            value: model.value
        )
    }

    func primaryIDs(matching value: Int) async throws -> [SchemaPrimaryID] {
        let registration = try await queryCore.register(
            SchemaPrimaryModel.self,
            fetchDescriptor: WebInspectorFetchDescriptor(
                predicate: #Predicate { $0.value == value }
            )
        )
        return try await registration.state().snapshot.itemIDs
    }

    func close() async {
        schemas.core.close().apply(on: schemas.owner, owner: context)
        await queryCore.close()
    }

    func isOnOwnerActor() -> Bool {
        self.preconditionIsolated()
        return true
    }

    private func publish(
        _ transaction: WebInspectorModelSchemaTransaction
    ) async throws {
        let commit = try await transaction.stage(on: queryCore)
        precondition(commit.publish(on: schemas.owner, owner: context))
    }
}

private actor SchemaContextOwnerActor {
    func materializes(
        registry: WebInspectorModelSchemaRegistry
    ) async throws -> Bool {
        let context = WebInspectorModelContext(
            modelSchemaRegistry: registry,
            isolation: self
        )
        let transaction = context.modelSchemaContextCore.initial(
            at: 0,
            snapshot: emptySchemaCanonicalSnapshot()
        )
        let commit = try await transaction.stage(
            on: context.fetchedResultsQueryCore
        )
        precondition(context.publish(commit))
        let id = SchemaPrimaryID(rawValue: 1)
        let ids = try await context.fetchIdentifiers(
            WebInspectorFetchDescriptor<SchemaPrimaryModel>()
        )
        let models = try await context.fetch(
            WebInspectorFetchDescriptor<SchemaPrimaryModel>()
        )
        let model = models.first
        let result = ids == [id]
            && models.count == 1
            && model?.value == 10
            && model === context.registeredModel(for: id)
        await context.close()
        return result && model?.isInvalidated == true
    }
}

private func emptySchemaCanonicalSnapshot() -> WebInspectorCanonicalModelSnapshot {
    WebInspectorCanonicalModelSnapshot(
        binding: nil,
        network: nil,
        DOM: nil,
        CSS: nil,
        consoleRuntime: nil
    )
}

@MainActor
private func applyContextSchemaInitial(
    to context: WebInspectorModelContext
) async throws {
    let transaction = context.modelSchemaContextCore.initial(
        at: 0,
        snapshot: emptySchemaCanonicalSnapshot()
    )
    let commit = try await transaction.stage(
        on: context.fetchedResultsQueryCore
    )
    #expect(context.publish(commit))
}

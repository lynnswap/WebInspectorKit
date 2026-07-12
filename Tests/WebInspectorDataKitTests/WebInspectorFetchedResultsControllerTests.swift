import Foundation
import Observation
import Testing
@testable import WebInspectorDataKit

@MainActor
@Test
func fetchedResultsControllerOwnsOneBackingAndSharedPublication() async throws {
    let context = ControllerTestContext.make()
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 10, group: "a", rank: 1),
            controllerRecord(id: 2, score: 20, group: "b", rank: 2),
        ]),
        at: 0,
        to: context
    )
    let controller = try await WebInspectorFetchedResultsController<
        ControllerTestModel,
        Never
    >(
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(controller.usesOneSharedPublicationForTesting)
    #expect(controller.revision == 0)
    #expect(controller.snapshot.itemIDs == [.init(1), .init(2)])

    var iterator = controller.updates().makeAsyncIterator()
    #expect(
        try await iterator.next()
            == .initial(
                revision: 0,
                snapshot: .init(itemIDs: [.init(1), .init(2)])
            )
    )

    let commit = try await context.fetchedResultsQueryCore.applyBatch(
        WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
            canonicalRevision: 1,
            changes: [
                .update(
                    controllerRecord(
                        id: 2,
                        score: 5,
                        group: "b",
                        rank: 2
                    )
                )
            ]
        )
    )
    #expect(controller.revision == 0)
    #expect(controller.publicationRevisionForTesting == 0)
    var controllerWasOldBeforeOwnerDelivery = false
    var publicationWasOldBeforeOwnerDelivery = false
    var controllerWasNewAfterOwnerDelivery = false
    var publicationWasOldAfterOwnerDelivery = false
    let didPublish = commit.publish { mutations in
        controllerWasOldBeforeOwnerDelivery = controller.revision == 0
        publicationWasOldBeforeOwnerDelivery =
            controller.publicationRevisionForTesting == 0
        context.applyFetchedResultsControllerOwnerMutations(mutations)
        controllerWasNewAfterOwnerDelivery = controller.revision == 1
        publicationWasOldAfterOwnerDelivery =
            controller.publicationRevisionForTesting == 0
    }
    #expect(didPublish)
    #expect(controllerWasOldBeforeOwnerDelivery)
    #expect(publicationWasOldBeforeOwnerDelivery)
    #expect(controllerWasNewAfterOwnerDelivery)
    #expect(publicationWasOldAfterOwnerDelivery)
    #expect(controller.publicationRevisionForTesting == 1)
    guard case let .changes(from, to, _, _, updatedIDs) = try await iterator.next() else {
        Issue.record("Expected one controller update.")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(updatedIDs == [.init(2)])

    await controller.close()
    let sibling = try await context.fetchedResultsQueryCore.register(
        ControllerTestModel.self
    )
    #expect(try await sibling.state().snapshot.itemIDs == [.init(1), .init(2)])
    await sibling.close()
    await context.close()
}

@MainActor
@Test
func fetchedResultsControllerReplacementAssignsDescriptorBeforeDelta() async throws {
    let context = ControllerTestContext.make()
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 10, group: "a", rank: 1),
            controllerRecord(id: 2, score: 20, group: "b", rank: 2),
        ]),
        at: 0,
        to: context
    )
    let controller = try await WebInspectorFetchedResultsController<
        ControllerTestModel,
        Never
    >(
        modelContext: context,
        isolation: MainActor.shared
    )
    var iterator = controller.updates().makeAsyncIterator()
    _ = try await iterator.next()

    let descriptor = WebInspectorFetchDescriptor<ControllerTestModel>(
        predicate: #Predicate { $0.score >= 20 }
    )
    try await controller.update(descriptor)
    #expect(controller.revision == 1)
    #expect(controller.publicationRevisionForTesting == 1)
    #expect(controller.snapshot.itemIDs == [.init(2)])
    guard case let .changes(from, to, _, itemChanges, _) = try await iterator.next() else {
        Issue.record("Expected a descriptor replacement delta.")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(
        itemChanges == [
            .delete(
                itemID: .init(1),
                indexPath: .init(section: 0, item: 0)
            )
        ]
    )

    try await controller.update(descriptor)
    #expect(controller.revision == 1)
    #expect(controller.publicationRevisionForTesting == 1)
    #expect(controller.snapshot.itemIDs == [.init(2)])
    await controller.close()
    await context.close()
}

@MainActor
@Test
func sectionedFetchedResultsControllerPublishesIDsWithoutMaterializingModels() async throws {
    let context = ControllerTestContext.make()
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 10, group: "first", rank: 1),
            controllerRecord(id: 2, score: 20, group: "second", rank: 2),
            controllerRecord(id: 3, score: 30, group: "first", rank: 3),
        ]),
        at: 0,
        to: context
    )
    let section: Expression<ControllerTestValue, String> = #Expression {
        $0.group
    }
    let controller = try await WebInspectorFetchedResultsController<
        ControllerTestModel,
        String
    >(
        sectionBy: section,
        modelContext: context,
        isolation: MainActor.shared
    )
    #expect(controller.snapshot.sectionNames == ["first", "second"])
    #expect(controller.snapshot.itemIDs(in: "first") == [.init(1), .init(3)])
    #expect(controller.snapshot.itemIDs(in: "second") == [.init(2)])
    await controller.close()
    await context.close()
}

@MainActor
@Test
func slowControllerSubscriberRebasesFromTheQueryOwnerOnlyWhenDequeued() async throws {
    let context = ControllerTestContext.make()
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 1, group: "a", rank: 1)
        ]),
        at: 0,
        to: context
    )
    let controller = try await WebInspectorFetchedResultsController<
        ControllerTestModel,
        Never
    >(
        modelContext: context,
        isolation: MainActor.shared
    )
    var iterator = controller.updates().makeAsyncIterator()
    _ = try await iterator.next()

    try await applyControllerSource(
        .insert(controllerRecord(id: 2, score: 2, group: "b", rank: 2)),
        at: 1,
        to: context
    )
    try await applyControllerSource(
        .insert(controllerRecord(id: 3, score: 3, group: "c", rank: 3)),
        at: 2,
        to: context
    )
    #expect(controller.revision == 2)
    guard case let .reset(revision, snapshot) = try await iterator.next() else {
        Issue.record("Expected a slow-controller reset.")
        return
    }
    #expect(revision == 2)
    #expect(snapshot.itemIDs == [.init(1), .init(2), .init(3)])
    await controller.close()
    await context.close()
}

@Test
func fetchedResultsControllerCanBeConfinedToACustomActor() async throws {
    let owner = ControllerCustomActor()
    #expect(try await owner.run())
}

@MainActor
@Test
func unsupportedControllerModelFailsBeforeInstallingAQuery() async throws {
    let context = WebInspectorModelContext()
    await #expect(throws: WebInspectorFetchedResultsControllerError.unsupportedModel) {
        _ = try await WebInspectorFetchedResultsController<
            ControllerTestModel,
            Never
        >(
            modelContext: context,
            isolation: MainActor.shared
        )
    }
    #expect(
        await context.fetchedResultsQueryCore.registrationCountForTesting(
            ControllerTestModel.self
        ) == 0
    )
    await context.close()
}

@MainActor
@Test
func controllerInitializationFailsCleanlyWhenContextClosesAfterClaimPreparation() async throws {
    let context = ControllerTestContext.make()
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 1, group: "a", rank: 1)
        ]),
        at: 0,
        to: context
    )
    let claim = try await context.fetchedResultsQueryCore
        .prepareControllerRegistration(ControllerTestModel.self)
    await context.close()

    await #expect(throws: WebInspectorFetchedResultsControllerError.closed) {
        _ = try await WebInspectorFetchedResultsController<
            ControllerTestModel,
            Never
        >(
            modelContext: context,
            claim: claim,
            isolation: MainActor.shared
        )
    }
    #expect(
        await context.fetchedResultsQueryCore.registrationCountForTesting(
            ControllerTestModel.self
        ) == 0
    )
}

@MainActor
@Test
func controllerInitializationCleansAnOwnerAfterCoreAbandonsItsAdmission() async throws {
    let context = ControllerTestContext.make()
    let core = context.fetchedResultsQueryCore
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 1, group: "a", rank: 1)
        ]),
        at: 0,
        to: context
    )
    let claim = try await core.prepareControllerRegistration(
        ControllerTestModel.self
    )
    #expect(claim.admission.abandon())
    await core.close()
    #expect(await core.hasOutstandingControllerAdmissionForTesting() == false)
    #expect(
        await core.registrationCountForTesting(ControllerTestModel.self) == 0
    )

    await #expect(throws: CancellationError.self) {
        _ = try await WebInspectorFetchedResultsController<
            ControllerTestModel,
            Never
        >(
            modelContext: context,
            claim: claim,
            isolation: MainActor.shared
        )
    }
    #expect(context.fetchedResultsControllerOwnerCountForTesting == 0)
    await claim.abandon()
    await context.close()
}

@MainActor
@Test
func concurrentControllerCloseConsumesAnAdmittedOwnerBatchAndLeavesContextLive() async throws {
    let context = ControllerTestContext.make()
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 1, group: "a", rank: 1)
        ]),
        at: 0,
        to: context
    )
    let controller = try await WebInspectorFetchedResultsController<
        ControllerTestModel,
        Never
    >(
        modelContext: context,
        isolation: MainActor.shared
    )
    let commit = try await context.fetchedResultsQueryCore.applyBatch(
        WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
            canonicalRevision: 1,
            changes: [
                .contentOnly(.init(1))
            ]
        )
    )

    let firstClose = Task { @MainActor in
        await controller.close()
    }
    for _ in 0..<10_000 where controller.isClosingForTesting == false {
        await Task.yield()
    }
    #expect(controller.isClosingForTesting)
    let secondClose = Task { @MainActor in
        await controller.close()
    }
    #expect(
        commit.publish { mutations in
            context.applyFetchedResultsControllerOwnerMutations(mutations)
        }
    )
    await firstClose.value
    await secondClose.value
    await controller.close()

    let sibling = try await context.fetchedResultsQueryCore.register(
        ControllerTestModel.self
    )
    #expect(try await sibling.state().snapshot.itemIDs == [.init(1)])
    await sibling.close()
    await context.close()
}

@MainActor
@Test
func contextCloseFinishesAControllerPrunedByAnAdmittedSourceBatch() async throws {
    let context = ControllerTestContext.make()
    let core = context.fetchedResultsQueryCore
    try await applyControllerSource(
        .reset([
            controllerRecord(id: 1, score: 1, group: "a", rank: 1)
        ]),
        at: 0,
        to: context
    )
    let claim = try await core.prepareControllerRegistration(
        ControllerTestModel.self
    )
    let controller = try await WebInspectorFetchedResultsController<
        ControllerTestModel,
        Never
    >(
        modelContext: context,
        claim: claim,
        isolation: MainActor.shared
    )
    var iterator = controller.updates().makeAsyncIterator()
    _ = try await iterator.next()

    // This is the owner-cancellation phase of context close. A source already
    // admitted behind that phase must carry the registration's terminal event
    // even though it prunes the cancelled registration from the query engine.
    claim.lease.cancel()
    let commit = try await core.applyBatch(
        WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
            canonicalRevision: 1,
            changes: [
                .contentOnly(.init(1))
            ]
        )
    )
    let close = Task { @MainActor in
        await context.close()
    }
    try await waitForControllerCondition {
        await core.isClosingForTesting()
    }

    #expect(
        commit.publish { mutations in
            context.applyFetchedResultsControllerOwnerMutations(mutations)
        }
    )
    #expect(try await iterator.next() == nil)
    await close.value
    await controller.close()
}

@Test
func activatedAdmissionCanBeResolvedBySourceBeforeClaimAcknowledgement() async throws {
    let core = try await seededControllerCore()
    let claim = try await core.prepareControllerRegistration(
        ControllerTestModel.self
    )
    let source = Task {
        try await core.applyBatch(
            WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
                canonicalRevision: 1,
                changes: [
                    .insert(controllerRecord(id: 2, score: 2, group: "b", rank: 2))
                ]
            )
        )
    }
    try await waitForControllerCondition {
        await core.outstandingControllerAdmissionWaiterCountForTesting() == 1
    }

    #expect(claim.admission.activate())
    try await waitForControllerCondition {
        await core.hasOutstandingControllerAdmissionForTesting() == false
    }
    try await claim.activate()
    let commit = try await source.value
    _ = await commit.abort(throwing: ControllerTestFailure.expectedAbort)
    #expect(await core.hasOutstandingControllerAdmissionForTesting() == false)
}

@Test
func abandonedAdmissionCanBeResolvedBySourceBeforeClaimAcknowledgement() async throws {
    let core = try await seededControllerCore()
    let claim = try await core.prepareControllerRegistration(
        ControllerTestModel.self
    )
    let source = Task {
        try await core.applyBatch(
            WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
                canonicalRevision: 1,
                changes: [
                    .insert(controllerRecord(id: 2, score: 2, group: "b", rank: 2))
                ]
            )
        )
    }
    try await waitForControllerCondition {
        await core.outstandingControllerAdmissionWaiterCountForTesting() == 1
    }

    #expect(claim.admission.abandon())
    try await waitForControllerCondition {
        await core.hasOutstandingControllerAdmissionForTesting() == false
    }
    await claim.abandon()
    let commit = try await source.value
    #expect(commit.publish())
    #expect(
        await core.registrationCountForTesting(ControllerTestModel.self) == 0
    )
    await core.close()
}

@Test
func deinitializedAdmissionClaimUnblocksSourceWithoutRetainedAcknowledgement() async throws {
    let core = try await seededControllerCore()
    var claim:
        WebInspectorFetchedResultsControllerRegistrationClaim<
            ControllerTestModel,
            Never
        >? = try await core.prepareControllerRegistration(ControllerTestModel.self)
    let source = Task {
        try await core.applyBatch(
            WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
                canonicalRevision: 1,
                changes: [
                    .insert(controllerRecord(id: 2, score: 2, group: "b", rank: 2))
                ]
            )
        )
    }
    try await waitForControllerCondition {
        await core.outstandingControllerAdmissionWaiterCountForTesting() == 1
    }

    #expect(claim != nil)
    claim = nil
    let commit = try await source.value
    #expect(commit.publish())
    #expect(await core.hasOutstandingControllerAdmissionForTesting() == false)
    #expect(
        await core.registrationCountForTesting(ControllerTestModel.self) == 0
    )

    let next = try await core.applyBatch(
        WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
            canonicalRevision: 2,
            changes: [
                .contentOnly(.init(1))
            ]
        )
    )
    #expect(next.publish())
    await core.close()
}

@Test
func contextCloseAbandonsAndResolvesAPendingControllerAdmission() async throws {
    let core = try await seededControllerCore()
    let claim = try await core.prepareControllerRegistration(
        ControllerTestModel.self
    )
    await core.close()
    await claim.abandon()
    #expect(await core.hasOutstandingControllerAdmissionForTesting() == false)
    #expect(
        await core.registrationCountForTesting(ControllerTestModel.self) == 0
    )
}

private enum ControllerTestContext {
    @MainActor
    static func make() -> WebInspectorModelContext {
        WebInspectorModelContext(
            configuredFetchedResultsModelTypes: [ControllerTestModel.self],
            isolation: MainActor.shared
        )
    }
}

private actor ControllerCustomActor {
    func run() async throws -> Bool {
        let context = WebInspectorModelContext(
            configuredFetchedResultsModelTypes: [ControllerTestModel.self],
            isolation: self
        )
        let initial = try await context.fetchedResultsQueryCore.applyBatch(
            WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
                canonicalRevision: 0,
                changes: [
                    .reset([
                        controllerRecord(id: 1, score: 1, group: "a", rank: 1)
                    ])
                ]
            )
        )
        initial.publish { mutations in
            context.applyFetchedResultsControllerOwnerMutations(mutations)
        }
        let controller = try await WebInspectorFetchedResultsController<
            ControllerTestModel,
            Never
        >(
            modelContext: context,
            isolation: self
        )
        let result =
            controller.snapshot.itemIDs == [.init(1)]
            && controller.usesOneSharedPublicationForTesting
        await controller.close()
        await context.close()
        return result
    }
}

private enum ControllerTestFailure: Error {
    case expectedAbort
    case conditionDidNotBecomeTrue
}

private struct ControllerTestID: WebInspectorPersistentIdentifier {
    typealias Model = ControllerTestModel
    let rawValue: Int

    init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

private struct ControllerTestValue: Identifiable, Sendable {
    let id: ControllerTestID
    let score: Int
    let group: String
}

@Observable
private final class ControllerTestModel: WebInspectorPersistentModel {
    typealias ID = ControllerTestID
    typealias QueryValue = ControllerTestValue

    nonisolated let id: ControllerTestID

    init(id: ControllerTestID) {
        self.id = id
    }
}

private func controllerRecord(
    id: Int,
    score: Int,
    group: String,
    rank: UInt64
) -> WebInspectorFetchedResultsSourceRecord<ControllerTestModel> {
    WebInspectorFetchedResultsSourceRecord(
        value: ControllerTestValue(
            id: ControllerTestID(id),
            score: score,
            group: group
        ),
        canonicalRank: .init(rawValue: rank)
    )
}

@MainActor
private func applyControllerSource(
    _ change: WebInspectorFetchedResultsSourceChange<ControllerTestModel>,
    at revision: UInt64,
    to context: WebInspectorModelContext
) async throws {
    let commit = try await context.fetchedResultsQueryCore.applyBatch(
        WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
            canonicalRevision: revision,
            changes: [change]
        )
    )
    #expect(
        commit.publish { mutations in
            context.applyFetchedResultsControllerOwnerMutations(mutations)
        }
    )
}

private func seededControllerCore() async throws -> WebInspectorModelContextCore {
    let core = WebInspectorModelContextCore()
    let commit = try await core.applyBatch(
        WebInspectorFetchedResultsSourceBatch<ControllerTestModel>(
            canonicalRevision: 0,
            changes: [
                .reset([
                    controllerRecord(id: 1, score: 1, group: "a", rank: 1)
                ])
            ]
        )
    )
    #expect(commit.publish())
    return core
}

private func waitForControllerCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<10_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw ControllerTestFailure.conditionDidNotBecomeTrue
}

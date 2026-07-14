import Foundation
import Observation
import Testing
@testable import WebInspectorDataKit

@Observable
private final class CutoverQueryModel: WebInspectorPersistentModel {
    struct ID: WebInspectorPersistentIdentifier {
        typealias Model = CutoverQueryModel
        let rawValue: Int
    }

    struct QueryValue: Identifiable, Sendable {
        let id: ID
        let score: Int
    }

    let id: ID
    private(set) var score: Int

    init(id: ID, score: Int) {
        self.id = id
        self.score = score
    }

    func replace(score: Int) {
        self.score = score
    }
}

private struct CutoverQueryRecord: Sendable {
    let score: Int
}

private let cutoverQuerySchema = WebInspectorModelSchema<
    CutoverQueryModel,
    CutoverQueryRecord
>(
    featureID: .network,
    makeModel: { _, id, record in
        CutoverQueryModel(id: id, score: record.score)
    },
    updateModel: { _, model, record in
        model.replace(score: record.score)
    },
    invalidateModel: { _, _ in }
)

@MainActor
@Test
func fetchedResultsPerformsInitialThenAppliesOneAtomicDelta() async throws {
    let registry = try WebInspectorModelSchemaRegistry([
        cutoverQuerySchema.erased
    ])
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network]),
        schemaRegistry: registry
    )
    let context = container.mainContext

    var initialTransaction = WebInspectorModelTransaction()
    initialTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 20),
            queryValue: .init(id: .init(rawValue: 2), score: 20),
            canonicalRank: .init(rawValue: 2)
        )
    )
    initialTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 10),
            queryValue: .init(id: .init(rawValue: 1), score: 10),
            canonicalRank: .init(rawValue: 1)
        )
    )
    initialTransaction.setFeatureState(
        .ready(
            generation: .init(rawValue: 1),
            revision: .init(rawValue: 0)
        ),
        for: .network
    )
    _ = try await container.modelStoreSink.commit(initialTransaction)

    let controller = WebInspectorFetchedResultsController<CutoverQueryModel>(
        fetchDescriptor: WebInspectorFetchDescriptor(
            sortBy: [SortDescriptor(\.score)]
        ),
        modelContext: context
    )
    try await controller.performFetch()

    #expect(controller.snapshot?.itemIDs.map(\.rawValue) == [1, 2])
    #expect(controller.fetchedObjects?.map(\.score) == [10, 20])
    #expect(controller.fetchedQueryValues?.map(\.score) == [10, 20])
    #expect(
        controller.fetchedQueryValue(for: .init(rawValue: 1))?.score == 10
    )

    var updates = controller.updates.makeAsyncIterator()
    guard case .initial = await updates.next() else {
        Issue.record("A late subscriber must start with the accepted initial state.")
        return
    }

    var updateTransaction = WebInspectorModelTransaction()
    updateTransaction.append(
        cutoverQuerySchema.upsert(
            record: CutoverQueryRecord(score: 30),
            queryValue: .init(id: .init(rawValue: 1), score: 30),
            canonicalRank: .init(rawValue: 1)
        )
    )
    _ = try await container.modelStoreSink.commit(updateTransaction)

    guard
        case let .changes(from, to, itemChanges, updatedItemIDs) =
            await updates.next()
    else {
        Issue.record("Expected one incremental fetched-results change.")
        return
    }
    #expect(to.rawValue == from.rawValue + 1)
    #expect(updatedItemIDs.map(\.rawValue) == [1])
    #expect(itemChanges.count == 1)
    #expect(controller.snapshot?.itemIDs.map(\.rawValue) == [2, 1])
    #expect(controller.fetchedQueryValues?.map(\.score) == [20, 30])
    #expect(
        controller.fetchedQueryValue(for: .init(rawValue: 1))?.score == 30
    )

    await controller.close()
    await context.close()
    await container.close()
}

@Test
func slowFetchedResultsSubscriberReceivesLatestReset() async {
    let publisher = _WebInspectorFetchedResultsUpdatePublisher<Int>()
    var iterator = publisher.sequence().makeAsyncIterator()

    publisher.publish(
        .initial(revision: .init(rawValue: 1), snapshot: .init(itemIDs: [1])),
        revision: .init(rawValue: 1),
        snapshot: .init(itemIDs: [1])
    )
    publisher.publish(
        .changes(
            fromRevision: .init(rawValue: 1),
            toRevision: .init(rawValue: 2),
            itemChanges: [.insert(itemID: 2, at: 1)],
            updatedItemIDs: []
        ),
        revision: .init(rawValue: 2),
        snapshot: .init(itemIDs: [1, 2])
    )
    publisher.publish(
        .changes(
            fromRevision: .init(rawValue: 2),
            toRevision: .init(rawValue: 3),
            itemChanges: [.insert(itemID: 3, at: 2)],
            updatedItemIDs: []
        ),
        revision: .init(rawValue: 3),
        snapshot: .init(itemIDs: [1, 2, 3])
    )

    guard case let .reset(revision, snapshot) = await iterator.next() else {
        Issue.record("Overflow must collapse to one latest reset.")
        return
    }
    #expect(revision.rawValue == 3)
    #expect(snapshot.itemIDs == [1, 2, 3])
    publisher.finish()
    let terminal = await iterator.next()
    #expect(terminal == nil)
}

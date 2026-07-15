import Foundation
import Observation
import Testing
import WebInspectorDataKit

@Test
func genericFetchedResultsValueSurfaceCompilesForAnExternalModel() throws {
    var descriptor = WebInspectorFetchDescriptor<ContractQueryModel>(
        predicate: #Predicate { $0.score > 0 },
        sortBy: [SortDescriptor(\.score)]
    )
    descriptor.fetchOffset = 1
    descriptor.fetchLimit = 10

    let id = ContractQueryID(rawValue: 1)
    let revision = WebInspectorFetchedResultsRevision(rawValue: 0)
    let snapshot = WebInspectorFetchedResultsSnapshot<ContractQueryID>(
        itemIDs: [id]
    )
    let update = WebInspectorFetchedResultsUpdate<ContractQueryID>.initial(
        revision: revision,
        snapshot: snapshot
    )

    #expect(snapshot.itemIDs == [id])
    #expect(descriptor.fetchOffset == 1)
    #expect(descriptor.fetchLimit == 10)
    guard case let .initial(updateRevision, updateSnapshot) = update else {
        Issue.record("Expected a flat initial fetched-results update.")
        return
    }
    #expect(updateRevision == revision)
    #expect(updateSnapshot.itemIDs == [id])

    requireUpdateSequence(
        WebInspectorFetchedResultsUpdateSequence<ContractQueryID>.self
    )
}

private func requireUpdateSequence<Sequence: AsyncSequence>(
    _: Sequence.Type
) where Sequence.Element == WebInspectorFetchedResultsUpdate<ContractQueryID> {}

private struct ContractQueryID: WebInspectorPersistentIdentifier {
    typealias Model = ContractQueryModel
    let rawValue: Int
}

private struct ContractQueryValue: Identifiable, Sendable {
    let id: ContractQueryID
    let score: Int
}

@Observable
private final class ContractQueryModel: WebInspectorPersistentModel {
    typealias ID = ContractQueryID
    typealias QueryValue = ContractQueryValue

    nonisolated let id: ContractQueryID

    init(id: ContractQueryID) {
        self.id = id
    }
}

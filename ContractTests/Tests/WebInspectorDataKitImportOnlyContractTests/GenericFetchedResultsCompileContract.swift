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
    let snapshot = WebInspectorFetchedResultsSnapshot<ContractQueryID, Never>(
        itemIDs: [id]
    )
    let update = WebInspectorFetchedResultsUpdate<ContractQueryID, Never>.initial(
        revision: 0,
        snapshot: snapshot
    )

    #expect(snapshot.sections.isEmpty)
    #expect(snapshot.itemIDs == [id])
    #expect(descriptor.fetchOffset == 1)
    #expect(descriptor.fetchLimit == 10)
    #expect(update == .initial(revision: 0, snapshot: snapshot))

    requireUpdateSequence(
        WebInspectorFetchedResultsUpdateSequence<ContractQueryID, Never>.self
    )
    requireSectionedSnapshot(
        WebInspectorFetchedResultsSnapshot<ContractQueryID, String>.self
    )
}

private func requireUpdateSequence<Sequence: AsyncSequence>(
    _: Sequence.Type
) where Sequence.Element == WebInspectorFetchedResultsUpdate<ContractQueryID, Never> {}

private func requireSectionedSnapshot<Snapshot>(_: Snapshot.Type) {}

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

#if canImport(UIKit)
import WebInspectorDataKit
import UIKit

package enum NetworkListSnapshotSection: Hashable, Sendable {
    case main
}

package struct NetworkListSnapshotBuildInput: Equatable, Sendable {
    package let entryIDs: [NetworkListEntry.ID]
    package let revision: UInt64

    package init(entryIDs: [NetworkListEntry.ID], revision: UInt64) {
        self.entryIDs = entryIDs
        self.revision = revision
    }
}

package struct NetworkListSnapshotArtifact: Sendable {
    package let input: NetworkListSnapshotBuildInput
    package let snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>

    package init(
        input: NetworkListSnapshotBuildInput,
        snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>
    ) {
        self.input = input
        self.snapshot = snapshot
    }
}

package protocol NetworkListSnapshotBuilding: Actor {
    func build(
        _ input: NetworkListSnapshotBuildInput
    ) async throws(CancellationError) -> NetworkListSnapshotArtifact
}

package protocol NetworkListSnapshotBuilderMaking: Sendable {
    func makeBuilder() -> any NetworkListSnapshotBuilding
}

package struct NetworkListSnapshotBuilderFactory: NetworkListSnapshotBuilderMaking {
    package init() {}

    package func makeBuilder() -> any NetworkListSnapshotBuilding {
        NetworkListSnapshotBuilder()
    }
}

package actor NetworkListSnapshotBuilder: NetworkListSnapshotBuilding {
    private static let cooperativeBatchSize = 256

    package init() {}

    package func build(
        _ input: NetworkListSnapshotBuildInput
    ) async throws(CancellationError) -> NetworkListSnapshotArtifact {
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        var uniqueEntryIDs = Set<NetworkListEntry.ID>()
        uniqueEntryIDs.reserveCapacity(input.entryIDs.count)
        var snapshot = NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>()
        snapshot.appendSections([.main])
        var lowerBound = 0
        while lowerBound < input.entryIDs.count {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let upperBound = min(
                lowerBound + Self.cooperativeBatchSize,
                input.entryIDs.count
            )
            let entryIDs = Array(input.entryIDs[lowerBound..<upperBound])
            for entryID in entryIDs {
                precondition(
                    uniqueEntryIDs.insert(entryID).inserted,
                    "Duplicate row IDs detected in NetworkListViewController"
                )
            }
            snapshot.appendItems(entryIDs, toSection: .main)
            lowerBound = upperBound
            await Task.yield()
        }
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        return NetworkListSnapshotArtifact(input: input, snapshot: snapshot)
    }
}
#endif

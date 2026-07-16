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

package actor NetworkListSnapshotBuilder: NetworkListSnapshotBuilding {
    package init() {}

    package func build(
        _ input: NetworkListSnapshotBuildInput
    ) async throws(CancellationError) -> NetworkListSnapshotArtifact {
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        precondition(
            input.entryIDs.count == Set(input.entryIDs).count,
            "Duplicate row IDs detected in NetworkListViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(input.entryIDs, toSection: .main)
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return NetworkListSnapshotArtifact(input: input, snapshot: snapshot)
    }
}
#endif

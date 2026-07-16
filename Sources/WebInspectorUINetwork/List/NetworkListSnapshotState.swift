#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

extension NetworkListViewController {
    struct SnapshotRows: Equatable, Sendable {
        let entryIDs: [NetworkListEntry.ID]

        init(entryIDs: [NetworkListEntry.ID]) {
            self.entryIDs = entryIDs
        }
    }
}

extension NetworkListViewController {
    @MainActor
    struct SnapshotState {
        private(set) var appliedRows = NetworkListViewController.SnapshotRows(entryIDs: [])
        private(set) var applyingRows: NetworkListViewController.SnapshotRows?
        private(set) var submittedBaseline: NetworkListSnapshotBaseline
        private var nextBaselineGeneration: UInt64 = 0

        init() {
            var snapshot = NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>()
            snapshot.appendSections([.main])
            submittedBaseline = NetworkListSnapshotBaseline(
                generation: 0,
                version: NetworkPanelListVersion(revision: 0, entryIdentityGeneration: 0),
                entryIDs: [],
                snapshot: snapshot
            )
        }

        var isApplying: Bool {
            applyingRows != nil
        }

        mutating func beginApplying(
            _ artifact: NetworkListSnapshotArtifact
        ) -> NetworkListViewController.SnapshotRows {
            precondition(
                applyingRows == nil,
                "A Network list snapshot apply must finish before another begins."
            )
            precondition(
                artifact.input.baseline.generation == submittedBaseline.generation,
                "A Network list snapshot apply must start from the submitted UIKit baseline."
            )
            precondition(
                nextBaselineGeneration < UInt64.max,
                "Network list snapshot baseline generation overflowed."
            )
            nextBaselineGeneration += 1
            let rows = NetworkListViewController.SnapshotRows(
                entryIDs: artifact.input.target.entryIDs
            )
            submittedBaseline = NetworkListSnapshotBaseline(
                generation: nextBaselineGeneration,
                version: artifact.input.target.version,
                entryIDs: artifact.input.target.entryIDs,
                snapshot: artifact.cleanSnapshot
            )
            applyingRows = rows
            return rows
        }

        mutating func acknowledgeUnchanged(
            _ artifact: NetworkListSnapshotArtifact
        ) {
            precondition(
                artifact.changeCounts.requiresApply == false,
                "Only a no-op Network list delta may advance without a UIKit apply."
            )
            precondition(
                artifact.input.baseline.generation == submittedBaseline.generation,
                "A no-op Network list delta must start from the submitted UIKit baseline."
            )
            submittedBaseline = NetworkListSnapshotBaseline(
                generation: submittedBaseline.generation,
                version: artifact.input.target.version,
                entryIDs: artifact.input.target.entryIDs,
                snapshot: artifact.cleanSnapshot
            )
        }

        mutating func finishApplying(_ rows: NetworkListViewController.SnapshotRows) {
            precondition(
                applyingRows == rows,
                "A Network list snapshot apply must finish the rows it started."
            )
            applyingRows = nil
            appliedRows = rows
        }
    }
}
#endif

#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit

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

        var isApplying: Bool {
            applyingRows != nil
        }

        mutating func beginApplying(_ rows: NetworkListViewController.SnapshotRows) {
            precondition(
                applyingRows == nil,
                "A Network list snapshot apply must finish before another begins."
            )
            applyingRows = rows
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

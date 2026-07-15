#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit

extension NetworkListViewController {
    @MainActor
    struct SnapshotRows: Equatable {
        let entryIDs: [NetworkListEntry.ID]

        init(entryIDs: [NetworkListEntry.ID]) {
            precondition(
                entryIDs.count == Set(entryIDs).count,
                "Duplicate row IDs detected in NetworkListViewController"
            )
            self.entryIDs = entryIDs
        }
    }
}

extension NetworkListViewController {
    @MainActor
    struct SnapshotState {
        private(set) var applyingRows: NetworkListViewController.SnapshotRows?

        var isApplying: Bool {
            applyingRows != nil
        }

        mutating func beginApplying(_ rows: NetworkListViewController.SnapshotRows) {
            applyingRows = rows
        }

        mutating func finishApplying(_ rows: NetworkListViewController.SnapshotRows) {
            applyingRows = nil
        }
    }
}
#endif

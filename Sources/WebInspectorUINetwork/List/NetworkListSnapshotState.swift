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

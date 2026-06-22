#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore

extension NetworkListViewController {
    @MainActor
    struct SnapshotRows: Equatable {
        let requestIDs: [NetworkRequest.ID]

        init(requestIDs: [NetworkRequest.ID]) {
            precondition(
                requestIDs.count == Set(requestIDs).count,
                "Duplicate row IDs detected in NetworkListViewController"
            )
            self.requestIDs = requestIDs
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

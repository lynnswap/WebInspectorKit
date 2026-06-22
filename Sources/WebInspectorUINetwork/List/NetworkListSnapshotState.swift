#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore

extension NetworkListViewController {
    @MainActor
    struct SnapshotRows: Equatable {
        let entryIDs: [NetworkDisplayEntry.ID]
        let presentationsByEntryID: [NetworkDisplayEntry.ID: NetworkDisplayEntryPresentation]

        init(
            entryIDs: [NetworkDisplayEntry.ID],
            presentationsByEntryID: [NetworkDisplayEntry.ID: NetworkDisplayEntryPresentation] = [:]
        ) {
            precondition(
                entryIDs.count == Set(entryIDs).count,
                "Duplicate row IDs detected in NetworkListViewController"
            )
            self.entryIDs = entryIDs
            self.presentationsByEntryID = presentationsByEntryID
        }

        init(displayRows: [NetworkDisplayRow]) {
            self.init(
                entryIDs: displayRows.map(\.id),
                presentationsByEntryID: Dictionary(
                    uniqueKeysWithValues: displayRows.map { ($0.id, $0.presentation) }
                )
            )
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

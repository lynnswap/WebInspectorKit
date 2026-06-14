#if canImport(UIKit)
import WebInspectorCore

extension NetworkListViewController {
    @MainActor
    struct SnapshotRows: Equatable {        let requestIDs: [NetworkRequest.ID]
        let projectionByID: [NetworkRequest.ID: NetworkRequest.Display.Projection]

        init(
            requestIDs: [NetworkRequest.ID],
            projectionByID: [NetworkRequest.ID: NetworkRequest.Display.Projection]
        ) {
            precondition(
                requestIDs.count == Set(requestIDs).count,
                "Duplicate row IDs detected in NetworkListViewController"
            )
            precondition(
                projectionByID.count == requestIDs.count
                    && requestIDs.allSatisfy { projectionByID[$0] != nil },
                "Network list snapshot rows and projections must describe the same IDs"
            )
            self.requestIDs = requestIDs
            self.projectionByID = projectionByID
        }

        init(displayRows: [NetworkRequest.Display.Projection]) {
            let requestIDs = displayRows.map(\.id)
            precondition(
                requestIDs.count == Set(requestIDs).count,
                "Duplicate row IDs detected in NetworkListViewController"
            )
            self.init(
                requestIDs: requestIDs,
                projectionByID: Dictionary(uniqueKeysWithValues: displayRows.map { ($0.id, $0) })
            )
        }
    }
}

extension NetworkListViewController {
    @MainActor
    struct SnapshotState {        private var displayedProjectionByID: [NetworkRequest.ID: NetworkRequest.Display.Projection] = [:]
        private(set) var applyingRows: NetworkListViewController.SnapshotRows?

        var isApplying: Bool {
            applyingRows != nil
        }

        func reconfiguredIDs(comparedTo rows: NetworkListViewController.SnapshotRows) -> Set<NetworkRequest.ID> {
            Set(rows.requestIDs.filter { id in
                guard let previous = displayedProjectionByID[id],
                      let next = rows.projectionByID[id] else {
                    return false
                }
                return previous != next
            })
        }

        func reconfiguredIDsAgainstApplyingRows(_ rows: NetworkListViewController.SnapshotRows) -> Set<NetworkRequest.ID> {
            guard let applyingRows else {
                return []
            }
            return Set(rows.requestIDs.filter { id in
                applyingRows.projectionByID[id] != rows.projectionByID[id]
            })
        }

        mutating func beginApplying(_ rows: NetworkListViewController.SnapshotRows) {
            applyingRows = rows
        }

        mutating func finishApplying(_ rows: NetworkListViewController.SnapshotRows) {
            displayedProjectionByID = rows.projectionByID
            applyingRows = nil
        }
    }
}
#endif

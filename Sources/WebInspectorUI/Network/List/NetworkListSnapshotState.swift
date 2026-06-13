#if canImport(UIKit)
import WebInspectorCore

@MainActor
struct NetworkListSnapshotRows: Equatable {
    let requestIDs: [NetworkRequest.ID]
    let projectionByID: [NetworkRequest.ID: NetworkRequestDisplayProjection]

    init(
        requestIDs: [NetworkRequest.ID],
        projectionByID: [NetworkRequest.ID: NetworkRequestDisplayProjection]
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

    init(displayRows: [NetworkRequestDisplayProjection]) {
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

@MainActor
struct NetworkListSnapshotState {
    private var displayedProjectionByID: [NetworkRequest.ID: NetworkRequestDisplayProjection] = [:]
    private(set) var applyingRows: NetworkListSnapshotRows?

    var isApplying: Bool {
        applyingRows != nil
    }

    func reconfiguredIDs(comparedTo rows: NetworkListSnapshotRows) -> Set<NetworkRequest.ID> {
        Set(rows.requestIDs.filter { id in
            guard let previous = displayedProjectionByID[id],
                  let next = rows.projectionByID[id] else {
                return false
            }
            return previous != next
        })
    }

    func reconfiguredIDsAgainstApplyingRows(_ rows: NetworkListSnapshotRows) -> Set<NetworkRequest.ID> {
        guard let applyingRows else {
            return []
        }
        return Set(rows.requestIDs.filter { id in
            applyingRows.projectionByID[id] != rows.projectionByID[id]
        })
    }

    mutating func beginApplying(_ rows: NetworkListSnapshotRows) {
        applyingRows = rows
    }

    mutating func finishApplying(_ rows: NetworkListSnapshotRows) {
        displayedProjectionByID = rows.projectionByID
        applyingRows = nil
    }
}
#endif

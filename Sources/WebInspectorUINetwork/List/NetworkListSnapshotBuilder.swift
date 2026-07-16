#if canImport(UIKit)
import UIKit

package enum NetworkListSnapshotSection: Hashable, Sendable {
    case main
}

package struct NetworkListSnapshotBaseline: Sendable {
    package let generation: UInt64
    package let version: NetworkPanelListVersion
    package let entryIDs: [NetworkListEntry.ID]
    package let snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>

    package init(
        generation: UInt64,
        version: NetworkPanelListVersion,
        entryIDs: [NetworkListEntry.ID],
        snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>
    ) {
        self.generation = generation
        self.version = version
        self.entryIDs = entryIDs
        self.snapshot = snapshot
    }
}

package struct NetworkListSnapshotBuildInput: Equatable, Sendable {
    package let baseline: NetworkListSnapshotBaseline
    package let target: NetworkPanelListProjection

    package init(
        baseline: NetworkListSnapshotBaseline,
        target: NetworkPanelListProjection
    ) {
        self.baseline = baseline
        self.target = target
    }

    package static func == (
        lhs: NetworkListSnapshotBuildInput,
        rhs: NetworkListSnapshotBuildInput
    ) -> Bool {
        lhs.baseline.generation == rhs.baseline.generation
            && lhs.baseline.version == rhs.baseline.version
            && lhs.baseline.entryIDs == rhs.baseline.entryIDs
            && lhs.target == rhs.target
    }
}

package struct NetworkListSnapshotChangeCounts: Equatable, Sendable {
    package let inserted: Int
    package let deleted: Int
    package let moved: Int
    package let reconfigured: Int

    package var requiresApply: Bool {
        inserted > 0 || deleted > 0 || moved > 0 || reconfigured > 0
    }
}

package struct NetworkListSnapshotArtifact: Sendable {
    package let input: NetworkListSnapshotBuildInput
    package let snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>
    package let cleanSnapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>
    package let changeCounts: NetworkListSnapshotChangeCounts

    package init(
        input: NetworkListSnapshotBuildInput,
        snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>,
        cleanSnapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>,
        changeCounts: NetworkListSnapshotChangeCounts
    ) {
        self.input = input
        self.snapshot = snapshot
        self.cleanSnapshot = cleanSnapshot
        self.changeCounts = changeCounts
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
        try checkCancellation()
        precondition(
            input.baseline.snapshot.sectionIdentifiers == [.main],
            "A Network list snapshot baseline must contain exactly the main section."
        )
        precondition(
            input.baseline.snapshot.itemIdentifiers == input.baseline.entryIDs,
            "A Network list snapshot baseline must own its declared row order."
        )

        let baselineEntryIDs = input.baseline.entryIDs
        let targetEntryIDs = input.target.entryIDs
        let baselineEntryIDSet = try await uniqueEntryIDs(in: baselineEntryIDs)
        let targetEntryIDSet = try await uniqueEntryIDs(in: targetEntryIDs)
        var snapshot = input.baseline.snapshot

        let deletedEntryIDs = baselineEntryIDs.filter { targetEntryIDSet.contains($0) == false }
        try await forEachBatch(in: deletedEntryIDs) { batch in
            snapshot.deleteItems(batch)
        }

        let retainedBaselineEntryIDs = baselineEntryIDs.filter(targetEntryIDSet.contains)
        let retainedTargetEntryIDs = targetEntryIDs.filter(baselineEntryIDSet.contains)
        let retainedBaselinePositions = Dictionary(
            uniqueKeysWithValues: retainedBaselineEntryIDs.enumerated().map { ($1, $0) }
        )
        let retainedTargetPositions = retainedTargetEntryIDs.map { entryID in
            guard let position = retainedBaselinePositions[entryID] else {
                preconditionFailure("A retained Network row must exist in the baseline.")
            }
            return position
        }
        let stationaryTargetIndices = try await longestIncreasingSubsequenceIndices(
            in: retainedTargetPositions
        )

        var movedCount = 0
        var nextTargetEntryID: NetworkListEntry.ID?
        var currentTailEntryID = retainedBaselineEntryIDs.last
        var processedMoveCount = 0
        for targetIndex in retainedTargetEntryIDs.indices.reversed() {
            let entryID = retainedTargetEntryIDs[targetIndex]
            if stationaryTargetIndices.contains(targetIndex) == false {
                if let nextTargetEntryID {
                    snapshot.moveItem(entryID, beforeItem: nextTargetEntryID)
                    movedCount += 1
                } else if let tailEntryID = currentTailEntryID, tailEntryID != entryID {
                    snapshot.moveItem(entryID, afterItem: tailEntryID)
                    currentTailEntryID = entryID
                    movedCount += 1
                }
            }
            nextTargetEntryID = entryID
            processedMoveCount += 1
            try await checkpointIfNeeded(processedCount: processedMoveCount)
        }

        var insertedCount = 0
        var previousTargetEntryID: NetworkListEntry.ID?
        var firstExistingEntryID = retainedTargetEntryIDs.first
        var processedInsertCount = 0
        for entryID in targetEntryIDs {
            if baselineEntryIDSet.contains(entryID) == false {
                if let previousTargetEntryID {
                    snapshot.insertItems([entryID], afterItem: previousTargetEntryID)
                } else if let firstExistingEntryID {
                    snapshot.insertItems([entryID], beforeItem: firstExistingEntryID)
                } else {
                    snapshot.appendItems([entryID], toSection: .main)
                    firstExistingEntryID = entryID
                }
                insertedCount += 1
            }
            previousTargetEntryID = entryID
            processedInsertCount += 1
            try await checkpointIfNeeded(processedCount: processedInsertCount)
        }

        precondition(
            snapshot.itemIdentifiers == targetEntryIDs,
            "A Network list snapshot delta must produce the exact target row order."
        )
        let cleanSnapshot = snapshot

        let entryIdentityAdvanced = input.target.version.entryIdentityGeneration
            > input.baseline.version.entryIdentityGeneration
        let reconfiguredEntryIDs = entryIdentityAdvanced
            ? targetEntryIDs.filter(baselineEntryIDSet.contains)
            : []
        try await forEachBatch(in: reconfiguredEntryIDs) { batch in
            snapshot.reconfigureItems(batch)
        }
        try checkCancellation()

        return NetworkListSnapshotArtifact(
            input: input,
            snapshot: snapshot,
            cleanSnapshot: cleanSnapshot,
            changeCounts: NetworkListSnapshotChangeCounts(
                inserted: insertedCount,
                deleted: deletedEntryIDs.count,
                moved: movedCount,
                reconfigured: reconfiguredEntryIDs.count
            )
        )
    }

    private func uniqueEntryIDs(
        in entryIDs: [NetworkListEntry.ID]
    ) async throws(CancellationError) -> Set<NetworkListEntry.ID> {
        var uniqueEntryIDs = Set<NetworkListEntry.ID>()
        uniqueEntryIDs.reserveCapacity(entryIDs.count)
        for (index, entryID) in entryIDs.enumerated() {
            precondition(
                uniqueEntryIDs.insert(entryID).inserted,
                "Duplicate row IDs detected in NetworkListViewController."
            )
            try await checkpointIfNeeded(processedCount: index + 1)
        }
        return uniqueEntryIDs
    }

    private func longestIncreasingSubsequenceIndices(
        in values: [Int]
    ) async throws(CancellationError) -> Set<Int> {
        guard values.isEmpty == false else {
            return []
        }

        var predecessorIndices = Array(repeating: -1, count: values.count)
        var tailIndices: [Int] = []
        tailIndices.reserveCapacity(values.count)

        for (index, value) in values.enumerated() {
            var lowerBound = 0
            var upperBound = tailIndices.count
            while lowerBound < upperBound {
                let candidate = lowerBound + (upperBound - lowerBound) / 2
                if values[tailIndices[candidate]] < value {
                    lowerBound = candidate + 1
                } else {
                    upperBound = candidate
                }
            }
            if lowerBound > 0 {
                predecessorIndices[index] = tailIndices[lowerBound - 1]
            }
            if lowerBound == tailIndices.count {
                tailIndices.append(index)
            } else {
                tailIndices[lowerBound] = index
            }
            try await checkpointIfNeeded(processedCount: index + 1)
        }

        var result = Set<Int>()
        var index = tailIndices.last ?? -1
        while index >= 0 {
            result.insert(index)
            index = predecessorIndices[index]
        }
        return result
    }

    private func forEachBatch(
        in entryIDs: [NetworkListEntry.ID],
        _ body: ([NetworkListEntry.ID]) -> Void
    ) async throws(CancellationError) {
        var lowerBound = 0
        while lowerBound < entryIDs.count {
            try checkCancellation()
            let upperBound = min(
                lowerBound + Self.cooperativeBatchSize,
                entryIDs.count
            )
            body(Array(entryIDs[lowerBound..<upperBound]))
            lowerBound = upperBound
            await Task.yield()
        }
        try checkCancellation()
    }

    private func checkpointIfNeeded(
        processedCount: Int
    ) async throws(CancellationError) {
        guard processedCount.isMultiple(of: Self.cooperativeBatchSize) else {
            return
        }
        try checkCancellation()
        await Task.yield()
        try checkCancellation()
    }

    private func checkCancellation() throws(CancellationError) {
        guard Task.isCancelled == false else {
            throw CancellationError()
        }
    }

}
#endif

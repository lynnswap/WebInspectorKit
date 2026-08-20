import Foundation

package struct NetworkResultSetDelta: Sendable {
    package var snapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
    package var transaction: WebInspectorFetchedResultsTransaction<NetworkRequest>
}

struct NetworkResultProjectionInput: Sendable {
    var plan: NetworkRequestQueryPlan
    var sectionBy: NetworkRequestQuery.Section?
    var oldSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
    var changedIDs: Set<NetworkRequest.ID>
}

struct NetworkRequestIndexClient: Sendable {
    final class Identity: Sendable {}

    let identity: Identity
    private let replaceBody: @Sendable ([NetworkRequestRecordInput], UInt64) async -> Void
    private let upsertBody: @Sendable (NetworkRequestRecordInput, UInt64) async -> Void
    private let deltasBody: @Sendable (
        [NetworkResultProjectionInput],
        UInt64
    ) async -> [NetworkResultSetDelta?]?
    private let fullProjectionRecordVisitCountBody: @Sendable () async -> Int

    init(
        identity: Identity = Identity(),
        replace: @escaping @Sendable ([NetworkRequestRecordInput], UInt64) async -> Void,
        upsert: @escaping @Sendable (NetworkRequestRecordInput, UInt64) async -> Void,
        deltas: @escaping @Sendable (
            [NetworkResultProjectionInput],
            UInt64
        ) async -> [NetworkResultSetDelta?]?,
        fullProjectionRecordVisitCount: @escaping @Sendable () async -> Int
    ) {
        self.identity = identity
        replaceBody = replace
        upsertBody = upsert
        deltasBody = deltas
        fullProjectionRecordVisitCountBody = fullProjectionRecordVisitCount
    }

    static func live() -> NetworkRequestIndexClient {
        let index = NetworkRequestIndex()
        return NetworkRequestIndexClient(
            replace: { inputs, sequence in
                await index.replace(with: inputs, sequence: sequence)
            },
            upsert: { input, sequence in
                await index.upsert(input, sequence: sequence)
            },
            deltas: { inputs, sequence in
                await index.deltas(for: inputs, sequence: sequence)
            },
            fullProjectionRecordVisitCount: {
#if DEBUG
                await index.fullProjectionRecordVisitCountForTesting
#else
                0
#endif
            }
        )
    }

    func replace(with inputs: [NetworkRequestRecordInput], sequence: UInt64) async {
        await replaceBody(inputs, sequence)
    }

    func upsert(_ input: NetworkRequestRecordInput, sequence: UInt64) async {
        await upsertBody(input, sequence)
    }

    func deltas(
        for inputs: [NetworkResultProjectionInput],
        sequence: UInt64
    ) async -> [NetworkResultSetDelta?]? {
        await deltasBody(inputs, sequence)
    }

    func fullProjectionRecordVisitCount() async -> Int {
        await fullProjectionRecordVisitCountBody()
    }
}

package actor NetworkRequestIndex {
    private var recordsByID: [NetworkRequest.ID: NetworkRequestRecord] = [:]
    private var orderedIDs: [NetworkRequest.ID] = []
    private var lastAppliedSequence: UInt64 = 0
#if DEBUG
    private var fullProjectionRecordVisitCountForTestingStorage = 0
#endif

    package init() {}

#if DEBUG
    package var fullProjectionRecordVisitCountForTesting: Int {
        fullProjectionRecordVisitCountForTestingStorage
    }
#endif

    package func replace(with inputs: [NetworkRequestRecordInput], sequence: UInt64) {
        guard apply(sequence: sequence) else {
            return
        }
        recordsByID = [:]
        recordsByID.reserveCapacity(inputs.count)
        orderedIDs = []
        orderedIDs.reserveCapacity(inputs.count)
        for input in inputs {
            upsertRecord(input)
        }
    }

    package func upsert(_ input: NetworkRequestRecordInput, sequence: UInt64) {
        guard apply(sequence: sequence) else {
            return
        }
        upsertRecord(input)
    }

    private func apply(sequence: UInt64) -> Bool {
        guard sequence > lastAppliedSequence else {
            return false
        }
        lastAppliedSequence = sequence
        return true
    }

    private func upsertRecord(_ input: NetworkRequestRecordInput) {
        let isNewRecord = recordsByID[input.id] == nil
        let record = NetworkRequestRecord(input: input)
        recordsByID[record.id] = record
        if isNewRecord {
            insertOrderedID(record.id, orderIndex: record.orderIndex)
        }
    }

    private func insertOrderedID(_ id: NetworkRequest.ID, orderIndex: Int) {
        var lowerBound = 0
        var upperBound = orderedIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            guard let midpointRecord = recordsByID[orderedIDs[midpoint]] else {
                preconditionFailure("NetworkRequestIndex order must reference an owned record.")
            }
            if midpointRecord.orderIndex < orderIndex {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        orderedIDs.insert(id, at: lowerBound)
    }

    package func delta(
        plan: NetworkRequestQueryPlan,
        sectionBy: NetworkRequestQuery.Section?,
        oldSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>,
        changedID: NetworkRequest.ID?
    ) -> NetworkResultSetDelta? {
        let newSnapshot = snapshot(plan: plan, sectionBy: sectionBy)
        guard let transaction = NetworkResultSetTransactionBuilder.transaction(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            changedIDs: changedID.map { [$0] } ?? []
        ) else {
            return nil
        }
        return NetworkResultSetDelta(snapshot: newSnapshot, transaction: transaction)
    }

    func deltas(
        for inputs: [NetworkResultProjectionInput],
        sequence: UInt64
    ) -> [NetworkResultSetDelta?]? {
        guard lastAppliedSequence == sequence else {
            return nil
        }
        return inputs.map { input in
            let newSnapshot = snapshot(plan: input.plan, sectionBy: input.sectionBy)
            guard let transaction = NetworkResultSetTransactionBuilder.transaction(
                oldSnapshot: input.oldSnapshot,
                newSnapshot: newSnapshot,
                changedIDs: input.changedIDs
            ) else {
                return nil
            }
            return NetworkResultSetDelta(snapshot: newSnapshot, transaction: transaction)
        }
    }

    private func snapshot(
        plan: NetworkRequestQueryPlan,
        sectionBy: NetworkRequestQuery.Section?
    ) -> WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> {
        let matchingRecords = visibleRecords(plan: plan)
        guard matchingRecords.isEmpty == false else {
            return WebInspectorFetchedResultsSnapshot()
        }
        guard let sectionBy else {
            return WebInspectorFetchedResultsSnapshot(itemIDs: matchingRecords.map(\.id))
        }

        var sections: [(
            id: WebInspectorFetchSectionID,
            title: String?,
            itemIDs: [NetworkRequest.ID]
        )] = []
        for record in matchingRecords {
            let identity = sectionIdentity(for: record, sectionBy: sectionBy)
            if let index = sections.firstIndex(where: { $0.id == identity.id }) {
                sections[index].itemIDs.append(record.id)
            } else {
                sections.append((
                    id: identity.id,
                    title: identity.title,
                    itemIDs: [record.id]
                ))
            }
        }
        return WebInspectorFetchedResultsSnapshot(sections: sections.map { section in
            WebInspectorFetchedResultsSnapshot.Section(
                id: section.id,
                title: section.title,
                itemIDs: section.itemIDs
            )
        })
    }

    private func visibleRecords(plan: NetworkRequestQueryPlan) -> [NetworkRequestRecord] {
        var records: [NetworkRequestRecord] = []
        records.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
#if DEBUG
            fullProjectionRecordVisitCountForTestingStorage &+= 1
#endif
            guard let record = recordsByID[id] else {
                preconditionFailure("NetworkRequestIndex order must reference an owned record.")
            }
            guard plan.matches(record: record) == true else {
                continue
            }
            records.append(record)
        }

        if plan.sortComparators.isEmpty == false {
            records.sort { lhs, rhs in
                plan.ordersBefore(lhs, rhs)
            }
        }

        let lowerBound = min(plan.fetchOffset, records.count)
        let remainingCount = records.count - lowerBound
        let visibleCount = min(plan.fetchLimit ?? remainingCount, remainingCount)
        let upperBound = lowerBound + visibleCount
        return Array(records[lowerBound..<upperBound])
    }

    private func sectionIdentity(
        for record: NetworkRequestRecord,
        sectionBy: NetworkRequestQuery.Section
    ) -> (id: WebInspectorFetchSectionID, title: String?) {
        let value: String?
        switch sectionBy.storage {
        case .method:
            value = record.method
        case .resourceType:
            value = record.resourceTypeRawValue
        case .resourceCategory:
            value = record.resourceCategory.rawValue
        case .mimeType:
            value = record.mimeType
        }

        let title = value ?? ""
        return (WebInspectorFetchSectionID(rawValue: title), title)
    }
}

private enum NetworkResultSetTransactionBuilder {
    typealias Snapshot = WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
    typealias ItemID = NetworkRequest.ID

    static func transaction(
        oldSnapshot: Snapshot,
        newSnapshot: Snapshot,
        changedIDs: Set<ItemID>
    ) -> WebInspectorFetchedResultsTransaction<NetworkRequest>? {
        let sectionChanges = sectionChanges(from: oldSnapshot, to: newSnapshot)
        let itemChanges = itemChanges(
            from: oldSnapshot,
            to: newSnapshot,
            changedIDs: changedIDs
        )
        let transaction = WebInspectorFetchedResultsTransaction<NetworkRequest>(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            isReset: false,
            sectionChanges: sectionChanges,
            itemChanges: itemChanges
        )
        return transaction.hasChanges ? transaction : nil
    }

    private static func sectionChanges(
        from oldSnapshot: Snapshot,
        to newSnapshot: Snapshot
    ) -> [WebInspectorFetchedResultsSectionChange] {
        let oldIndexes = indexSections(oldSnapshot.sections)
        let newIndexes = indexSections(newSnapshot.sections)

        let deletes = oldSnapshot.sections.enumerated()
            .filter { _, section in newIndexes[section.id] == nil }
            .sorted { lhs, rhs in lhs.offset > rhs.offset }
            .map { index, section in
                WebInspectorFetchedResultsSectionChange.delete(sectionID: section.id, index: index)
            }

        let inserts = newSnapshot.sections.enumerated()
            .filter { _, section in oldIndexes[section.id] == nil }
            .map { index, section in
                WebInspectorFetchedResultsSectionChange.insert(sectionID: section.id, index: index)
            }

        let moves = newSnapshot.sections.enumerated()
            .compactMap { newIndex, section -> WebInspectorFetchedResultsSectionChange? in
                guard let oldIndex = oldIndexes[section.id], oldIndex != newIndex else {
                    return nil
                }
                return .move(sectionID: section.id, from: oldIndex, to: newIndex)
            }

        let updates = newSnapshot.sections.enumerated()
            .compactMap { newIndex, section -> WebInspectorFetchedResultsSectionChange? in
                guard let oldIndex = oldIndexes[section.id] else {
                    return nil
                }
                guard oldSnapshot.sections[oldIndex].title != section.title else {
                    return nil
                }
                return .update(sectionID: section.id, index: newIndex)
            }

        return deletes + inserts + moves + updates
    }

    private static func itemChanges(
        from oldSnapshot: Snapshot,
        to newSnapshot: Snapshot,
        changedIDs: Set<ItemID>
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        let oldPositions = indexItems(oldSnapshot)
        let newPositions = indexItems(newSnapshot)

        let deletes = oldPositions.values
            .filter { newPositions[$0.itemID] == nil }
            .sorted { lhs, rhs in lhs.indexPath > rhs.indexPath }
            .map {
                WebInspectorFetchedResultsItemChange.delete(
                    itemID: $0.itemID,
                    indexPath: $0.indexPath
                )
            }

        let inserts = newPositions.values
            .filter { oldPositions[$0.itemID] == nil }
            .sorted { lhs, rhs in lhs.indexPath < rhs.indexPath }
            .map {
                WebInspectorFetchedResultsItemChange.insert(
                    itemID: $0.itemID,
                    indexPath: $0.indexPath
                )
            }

        let sectionMembershipChanges = sectionMembershipChanges(
            from: oldSnapshot,
            to: newSnapshot,
            oldPositions: oldPositions,
            newPositions: newPositions
        )

        let moves = moveChanges(
            from: oldSnapshot,
            to: newSnapshot,
            oldPositions: oldPositions,
            newPositions: newPositions,
            changedIDs: changedIDs,
            excludedItemIDs: Set(sectionMembershipChanges.map(itemID))
        )
        let updates = updateChanges(
            from: oldPositions,
            to: newPositions,
            changedIDs: changedIDs,
            excludedItemIDs: Set(
                (deletes + inserts + sectionMembershipChanges + moves).map(itemID)
            )
        )

        return deletes + inserts + sectionMembershipChanges + moves + updates
    }

    private static func updateChanges(
        from oldPositions: [ItemID: ItemPosition],
        to newPositions: [ItemID: ItemPosition],
        changedIDs: Set<ItemID>,
        excludedItemIDs: Set<ItemID>
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        changedIDs.compactMap { changedID -> (ItemID, WebInspectorFetchedResultsIndexPath)? in
            guard excludedItemIDs.contains(changedID) == false,
                  let oldPosition = oldPositions[changedID],
                  let newPosition = newPositions[changedID],
                  oldPosition.sectionID == newPosition.sectionID else {
                return nil
            }
            return (changedID, newPosition.indexPath)
        }.sorted { lhs, rhs in
            lhs.1 < rhs.1
        }.map { changedID, indexPath in
            .update(itemID: changedID, indexPath: indexPath)
        }
    }

    private static func sectionMembershipChanges(
        from oldSnapshot: Snapshot,
        to newSnapshot: Snapshot,
        oldPositions: [ItemID: ItemPosition],
        newPositions: [ItemID: ItemPosition]
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        let oldSectionIDs = Set(oldSnapshot.sectionIDs)
        let newSectionIDs = Set(newSnapshot.sectionIDs)
        let deletedSectionIDs = oldSectionIDs.subtracting(newSectionIDs)
        let insertedSectionIDs = newSectionIDs.subtracting(oldSectionIDs)

        return newSnapshot.itemIDs.compactMap { itemID -> WebInspectorFetchedResultsItemChange<ItemID>? in
            guard let oldPosition = oldPositions[itemID],
                  let newPosition = newPositions[itemID],
                  oldPosition.sectionID != newPosition.sectionID else {
                return nil
            }
            let oldSectionDeleted = deletedSectionIDs.contains(oldPosition.sectionID)
            let newSectionInserted = insertedSectionIDs.contains(newPosition.sectionID)
            switch (oldSectionDeleted, newSectionInserted) {
            case (true, true):
                return nil
            case (true, false):
                return .insert(itemID: itemID, indexPath: newPosition.indexPath)
            case (false, true):
                return .delete(itemID: itemID, indexPath: oldPosition.indexPath)
            case (false, false):
                return .move(
                    itemID: itemID,
                    from: oldPosition.indexPath,
                    to: newPosition.indexPath
                )
            }
        }
    }

    private static func moveChanges(
        from oldSnapshot: Snapshot,
        to newSnapshot: Snapshot,
        oldPositions: [ItemID: ItemPosition],
        newPositions: [ItemID: ItemPosition],
        changedIDs: Set<ItemID>,
        excludedItemIDs: Set<ItemID>
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        let oldCommonOrder = oldSnapshot.itemIDs.filter { newPositions[$0] != nil }
        let newCommonOrder = newSnapshot.itemIDs.filter { oldPositions[$0] != nil }
        guard oldCommonOrder != newCommonOrder else {
            return []
        }

        if changedIDs.count == 1,
           let changedID = changedIDs.first,
           excludedItemIDs.contains(changedID) == false,
           let oldPosition = oldPositions[changedID],
           let newPosition = newPositions[changedID],
           oldPosition.sectionID == newPosition.sectionID,
           oldPosition.indexPath != newPosition.indexPath {
            return [
                .move(
                    itemID: changedID,
                    from: oldPosition.indexPath,
                    to: newPosition.indexPath
                ),
            ]
        }

        return newCommonOrder.compactMap { itemID -> WebInspectorFetchedResultsItemChange<ItemID>? in
            guard excludedItemIDs.contains(itemID) == false else {
                return nil
            }
            guard let oldPosition = oldPositions[itemID],
                  let newPosition = newPositions[itemID],
                  oldPosition.sectionID == newPosition.sectionID,
                  oldPosition.indexPath != newPosition.indexPath else {
                return nil
            }
            return .move(
                itemID: itemID,
                from: oldPosition.indexPath,
                to: newPosition.indexPath
            )
        }
    }

    private static func indexSections(
        _ sections: [Snapshot.Section]
    ) -> [WebInspectorFetchSectionID: Int] {
        Dictionary(
            uniqueKeysWithValues: sections.enumerated().map { index, section in
                (section.id, index)
            }
        )
    }

    private struct ItemPosition {
        var itemID: ItemID
        var sectionID: WebInspectorFetchSectionID
        var indexPath: WebInspectorFetchedResultsIndexPath
    }

    private static func indexItems(_ snapshot: Snapshot) -> [ItemID: ItemPosition] {
        var positions: [ItemID: ItemPosition] = [:]
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            for (itemIndex, itemID) in section.itemIDs.enumerated() where positions[itemID] == nil {
                positions[itemID] = ItemPosition(
                    itemID: itemID,
                    sectionID: section.id,
                    indexPath: WebInspectorFetchedResultsIndexPath(
                        section: sectionIndex,
                        item: itemIndex
                    )
                )
            }
        }
        return positions
    }

    private static func itemID(
        for change: WebInspectorFetchedResultsItemChange<ItemID>
    ) -> ItemID {
        switch change {
        case let .insert(itemID, _),
             let .delete(itemID, _),
             let .update(itemID, _),
             let .move(itemID, _, _):
            return itemID
        }
    }
}

import Foundation

package struct NetworkResultSetDelta: Sendable {
    package var snapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
    package var transaction: WebInspectorFetchedResultsTransaction<NetworkRequest>?
}

package actor NetworkRequestIndex {
    private var recordsByID: [NetworkRequest.ID: NetworkRequestRecord] = [:]
    private var orderedIDs: [NetworkRequest.ID] = []
    private var lastAppliedSequence: UInt64 = 0

    package init() {}

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
            orderedIDs.append(record.id)
        }
    }

    package func delta(
        plan: NetworkRequestQueryPlan,
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>?,
        oldSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>,
        changedID: NetworkRequest.ID?
    ) -> NetworkResultSetDelta? {
        guard plan.requiresModelPredicate == false else {
            return nil
        }
        let newSnapshot = snapshot(plan: plan, sectionBy: sectionBy)
        guard oldSnapshot != newSnapshot else {
            return nil
        }
        let transaction = NetworkResultSetTransactionBuilder.transaction(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            changedID: changedID
        )
        return NetworkResultSetDelta(snapshot: newSnapshot, transaction: transaction)
    }

    private func snapshot(
        plan: NetworkRequestQueryPlan,
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>?
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
            guard let record = recordsByID[id] else {
                continue
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
        let upperBound: Int
        if let fetchLimit = plan.fetchLimit {
            upperBound = min(lowerBound + fetchLimit, records.count)
        } else {
            upperBound = records.count
        }
        return Array(records[lowerBound..<upperBound])
    }

    private func sectionIdentity(
        for record: NetworkRequestRecord,
        sectionBy: WebInspectorSectionDescriptor<NetworkRequest>
    ) -> (id: WebInspectorFetchSectionID, title: String?) {
        let value: String?
        switch sectionBy.key {
        case .networkMethod:
            value = record.method
        case .networkResourceType:
            value = record.resourceTypeRawValue
        case .networkResourceCategory:
            value = record.resourceCategory.rawValue
        case .networkMIMEType:
            value = record.mimeType
        case .consoleSource,
             .consoleLevel,
             .consoleKind,
             .consoleURL:
            preconditionFailure("Console section descriptors cannot be applied to NetworkRequest results.")
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
        changedID: ItemID?
    ) -> WebInspectorFetchedResultsTransaction<NetworkRequest>? {
        let sectionChanges = sectionChanges(from: oldSnapshot, to: newSnapshot)
        let itemChanges = itemChanges(from: oldSnapshot, to: newSnapshot, changedID: changedID)
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
        changedID: ItemID?
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
            changedID: changedID,
            excludedItemIDs: Set(sectionMembershipChanges.map(itemID))
        )

        return deletes + inserts + sectionMembershipChanges + moves
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
        changedID: ItemID?,
        excludedItemIDs: Set<ItemID>
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        let oldCommonOrder = oldSnapshot.itemIDs.filter { newPositions[$0] != nil }
        let newCommonOrder = newSnapshot.itemIDs.filter { oldPositions[$0] != nil }
        guard oldCommonOrder != newCommonOrder else {
            return []
        }

        if let changedID,
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

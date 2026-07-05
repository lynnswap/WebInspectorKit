import Foundation

public struct WebInspectorFetchedResultsIndexPath: Hashable, Sendable {
    public var section: Int
    public var item: Int

    public init(section: Int, item: Int) {
        self.section = section
        self.item = item
    }
}

public struct WebInspectorFetchedResultsSnapshot<ItemID: Hashable & Sendable>: Hashable, Sendable {
    public struct Section: Identifiable, Hashable, Sendable {
        public let id: WebInspectorFetchSectionID
        public let title: String?
        public let itemIDs: [ItemID]

        public init(id: WebInspectorFetchSectionID, title: String?, itemIDs: [ItemID]) {
            self.id = id
            self.title = title
            self.itemIDs = itemIDs
        }
    }

    public let sections: [Section]

    public init(sections: [Section] = []) {
        self.sections = sections
        let itemIDs = sections.flatMap(\.itemIDs)
        precondition(
            Set(itemIDs).count == itemIDs.count,
            "WebInspectorFetchedResultsSnapshot item IDs must be unique."
        )
    }

    public init(itemIDs: [ItemID]) {
        self.init(sections: [
            Section(id: .defaultSection, title: nil, itemIDs: itemIDs)
        ])
    }

    public var sectionIDs: [WebInspectorFetchSectionID] {
        sections.map(\.id)
    }

    public var itemIDs: [ItemID] {
        sections.flatMap(\.itemIDs)
    }

    public func itemIDs(in sectionID: WebInspectorFetchSectionID) -> [ItemID]? {
        sections.first { $0.id == sectionID }?.itemIDs
    }
}

extension WebInspectorFetchedResultsSnapshot {
    init<Model: WebInspectorFetchableModel>(
        sections: [WebInspectorFetchSection<Model>]
    ) where Model.ID == ItemID {
        self.init(sections: sections.map { section in
            Section(
                id: section.id,
                title: section.title,
                itemIDs: section.items.map(\.id)
            )
        })
    }
}

public enum WebInspectorFetchedResultsSectionChange: Hashable, Sendable {
    case insert(sectionID: WebInspectorFetchSectionID, index: Int)
    case delete(sectionID: WebInspectorFetchSectionID, index: Int)
    case move(sectionID: WebInspectorFetchSectionID, from: Int, to: Int)
    case update(sectionID: WebInspectorFetchSectionID, index: Int)
}

public enum WebInspectorFetchedResultsItemChange<ItemID: Hashable & Sendable>: Hashable, Sendable {
    case insert(itemID: ItemID, indexPath: WebInspectorFetchedResultsIndexPath)
    case delete(itemID: ItemID, indexPath: WebInspectorFetchedResultsIndexPath)
    case move(
        itemID: ItemID,
        from: WebInspectorFetchedResultsIndexPath,
        to: WebInspectorFetchedResultsIndexPath
    )
    case update(itemID: ItemID, indexPath: WebInspectorFetchedResultsIndexPath)
}

public struct WebInspectorFetchedResultsTransaction<Model: WebInspectorFetchableModel>: Hashable, Sendable {
    public typealias ItemID = Model.ID

    public let oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    public let newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    public let isReset: Bool
    public let sectionChanges: [WebInspectorFetchedResultsSectionChange]
    public let itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>]

    public var hasChanges: Bool {
        isReset || sectionChanges.isEmpty == false || itemChanges.isEmpty == false
    }

    public init(
        oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        isReset: Bool = false,
        sectionChanges: [WebInspectorFetchedResultsSectionChange] = [],
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>]
    ) {
        self.oldSnapshot = oldSnapshot
        self.newSnapshot = newSnapshot
        self.isReset = isReset
        self.sectionChanges = sectionChanges
        self.itemChanges = itemChanges
    }

    init(
        oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        updatedItemIDs: Set<ItemID> = []
    ) {
        self.init(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            isReset: false,
            sectionChanges: Self.sectionChanges(from: oldSnapshot, to: newSnapshot),
            itemChanges: Self.itemChanges(from: oldSnapshot, to: newSnapshot, updatedItemIDs: updatedItemIDs)
        )
    }

    private static func sectionChanges(
        from oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        to newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>
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

    private static func indexSections(
        _ sections: [WebInspectorFetchedResultsSnapshot<ItemID>.Section]
    ) -> [WebInspectorFetchSectionID: Int] {
        Dictionary(
            uniqueKeysWithValues: sections.enumerated().map { index, section in
                (section.id, index)
            }
        )
    }

    private static func itemChanges(
        from oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        to newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        updatedItemIDs: Set<ItemID>
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

        let moves = newPositions.values
            .compactMap { newPosition -> WebInspectorFetchedResultsItemChange<ItemID>? in
                guard let oldPosition = oldPositions[newPosition.itemID],
                      oldPosition.indexPath != newPosition.indexPath else {
                    return nil
                }
                return .move(
                    itemID: newPosition.itemID,
                    from: oldPosition.indexPath,
                    to: newPosition.indexPath
                )
            }
            .sorted { lhs, rhs in
                lhs.newIndexPathForOrdering < rhs.newIndexPathForOrdering
            }

        let updates = newPositions.values
            .compactMap { newPosition -> WebInspectorFetchedResultsItemChange<ItemID>? in
                guard oldPositions[newPosition.itemID] != nil,
                      updatedItemIDs.contains(newPosition.itemID) else {
                    return nil
                }
                return .update(itemID: newPosition.itemID, indexPath: newPosition.indexPath)
            }
            .sorted { lhs, rhs in
                lhs.newIndexPathForOrdering < rhs.newIndexPathForOrdering
            }

        return deletes + inserts + moves + updates
    }

    private struct ItemPosition {
        var itemID: ItemID
        var indexPath: WebInspectorFetchedResultsIndexPath
    }

    private static func indexItems(
        _ snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    ) -> [ItemID: ItemPosition] {
        var positions: [ItemID: ItemPosition] = [:]
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            for (itemIndex, itemID) in section.itemIDs.enumerated() where positions[itemID] == nil {
                positions[itemID] = ItemPosition(
                    itemID: itemID,
                    indexPath: WebInspectorFetchedResultsIndexPath(
                        section: sectionIndex,
                        item: itemIndex
                    )
                )
            }
        }
        return positions
    }
}

extension WebInspectorFetchedResultsItemChange {
    fileprivate var newIndexPathForOrdering: WebInspectorFetchedResultsIndexPath {
        switch self {
        case .insert(_, let indexPath),
             .update(_, let indexPath),
             .delete(_, let indexPath):
            return indexPath
        case .move(_, _, let indexPath):
            return indexPath
        }
    }
}

extension WebInspectorFetchedResultsIndexPath: Comparable {
    public static func < (
        lhs: WebInspectorFetchedResultsIndexPath,
        rhs: WebInspectorFetchedResultsIndexPath
    ) -> Bool {
        if lhs.section != rhs.section {
            return lhs.section < rhs.section
        }
        return lhs.item < rhs.item
    }
}

public final class WebInspectorFetchedResultsController<Model: WebInspectorFetchableModel> {
    public let fetchedResults: WebInspectorFetchedResults<Model>

    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        fetchedResults.fetchDescriptor
    }

    public var items: [Model] {
        fetchedResults.items
    }

    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID> {
        WebInspectorFetchedResultsSnapshot(sections: fetchedResults.sections)
    }

    public var transactions: AsyncStream<WebInspectorFetchedResultsTransaction<Model>> {
        fetchedResults.makeTransactionStream()
    }

    public init(fetchedResults: WebInspectorFetchedResults<Model>) {
        self.fetchedResults = fetchedResults
    }

    public func updateFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        isolation: isolated (any Actor) = #isolation
    ) {
        fetchedResults.updateFetchDescriptor(descriptor, isolation: isolation)
    }
}

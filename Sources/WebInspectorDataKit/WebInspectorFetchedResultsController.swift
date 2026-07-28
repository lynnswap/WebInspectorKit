import Foundation

/// Section/item position inside fetched results.
public struct WebInspectorFetchedResultsIndexPath: Hashable, Sendable {
    /// The section index.
    public var section: Int

    /// The item index within the section.
    public var item: Int

    /// Creates an index path.
    public init(section: Int, item: Int) {
        self.section = section
        self.item = item
    }
}

/// Immutable snapshot of fetched-result section and item identities.
public struct WebInspectorFetchedResultsSnapshot<ItemID: Hashable & Sendable>: Hashable, Sendable {
    /// One section in a fetched-results snapshot.
    public struct Section: Identifiable, Hashable, Sendable {
        /// The stable section identity.
        public let id: WebInspectorFetchSectionID

        /// The display title for the section.
        public let title: String?

        /// Item identities in section order.
        public let itemIDs: [ItemID]

        /// Creates a snapshot section.
        public init(id: WebInspectorFetchSectionID, title: String?, itemIDs: [ItemID]) {
            self.id = id
            self.title = title
            self.itemIDs = itemIDs
        }
    }

    /// Sections in display order.
    public let sections: [Section]

    /// Creates a fetched-results snapshot.
    public init(sections: [Section] = []) {
        self.sections = sections
        let itemIDs = sections.flatMap(\.itemIDs)
        precondition(
            Set(itemIDs).count == itemIDs.count,
            "WebInspectorFetchedResultsSnapshot item IDs must be unique."
        )
    }

    /// Creates a single-section snapshot from item identities.
    public init(itemIDs: [ItemID]) {
        self.init(sections: [
            Section(id: .defaultSection, title: nil, itemIDs: itemIDs)
        ])
    }

    /// Section identities in display order.
    public var sectionIDs: [WebInspectorFetchSectionID] {
        sections.map(\.id)
    }

    /// All item identities in display order.
    public var itemIDs: [ItemID] {
        sections.flatMap(\.itemIDs)
    }

    /// Returns item identities for a section.
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

/// Section-level change in a fetched-results transaction.
public enum WebInspectorFetchedResultsSectionChange: Hashable, Sendable {
    /// A section was inserted.
    case insert(sectionID: WebInspectorFetchSectionID, index: Int)

    /// A section was deleted.
    case delete(sectionID: WebInspectorFetchSectionID, index: Int)

    /// A section moved.
    case move(sectionID: WebInspectorFetchSectionID, from: Int, to: Int)

    /// A section's display metadata changed.
    case update(sectionID: WebInspectorFetchSectionID, index: Int)
}

/// Item-level change in a fetched-results transaction.
public enum WebInspectorFetchedResultsItemChange<ItemID: Hashable & Sendable>: Hashable, Sendable {
    /// An item was inserted.
    case insert(itemID: ItemID, indexPath: WebInspectorFetchedResultsIndexPath)

    /// An item was deleted.
    case delete(itemID: ItemID, indexPath: WebInspectorFetchedResultsIndexPath)

    /// An item moved.
    case move(
        itemID: ItemID,
        from: WebInspectorFetchedResultsIndexPath,
        to: WebInspectorFetchedResultsIndexPath
    )
    /// An item's model changed without moving.
    case update(itemID: ItemID, indexPath: WebInspectorFetchedResultsIndexPath)
}

/// A batch of fetched-results changes between two snapshots.
public struct WebInspectorFetchedResultsTransaction<Model: WebInspectorFetchableModel>: Hashable, Sendable {
    /// Item identity type for the model.
    public typealias ItemID = Model.ID

    /// Snapshot before the transaction.
    public let oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>

    /// Snapshot after the transaction.
    public let newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>

    /// A Boolean value indicating whether consumers should treat the change as a full reset.
    public let isReset: Bool

    /// Section changes in application order.
    public let sectionChanges: [WebInspectorFetchedResultsSectionChange]

    /// Item changes in application order.
    public let itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>]

    /// A Boolean value indicating whether the transaction contains any changes.
    public var hasChanges: Bool {
        isReset || sectionChanges.isEmpty == false || itemChanges.isEmpty == false
    }

    /// Creates a fetched-results transaction.
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
                guard let oldPosition = oldPositions[newPosition.itemID],
                      oldPosition.sectionID == newPosition.sectionID,
                      oldPosition.indexPath == newPosition.indexPath,
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
        var sectionID: WebInspectorFetchSectionID
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
    /// Orders index paths by section and then item.
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

/// Controller wrapper around ``WebInspectorFetchedResults``.
public final class WebInspectorFetchedResultsController<Model: WebInspectorFetchableModel> {
    /// The observable fetched-results model.
    public let fetchedResults: WebInspectorFetchedResults<Model>

    /// The descriptor currently used by the results.
    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        fetchedResults.fetchDescriptor
    }

    /// The fetched models in display order.
    public var items: [Model] {
        fetchedResults.items
    }

    /// The current fetched-results snapshot.
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID> {
        WebInspectorFetchedResultsSnapshot(sections: fetchedResults.sections)
    }

    /// Stream of transactions emitted after result changes.
    public var transactions: AsyncStream<WebInspectorFetchedResultsTransaction<Model>> {
        fetchedResults.makeTransactionStream()
    }

    /// Creates a controller for fetched results.
    public init(fetchedResults: WebInspectorFetchedResults<Model>) {
        self.fetchedResults = fetchedResults
    }

    /// Replaces the fetch descriptor and updates the result contents.
    public func updateFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        isolation: isolated (any Actor) = #isolation
    ) {
        fetchedResults.updateFetchDescriptor(descriptor, isolation: isolation)
    }
}

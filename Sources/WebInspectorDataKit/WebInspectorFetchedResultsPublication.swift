import Foundation
import Synchronization

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
    init<Model: Identifiable>(
        sections: [WebInspectorFetchSection<Model>]
    ) where Model.ID == ItemID, Model.ID: Hashable & Sendable {
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
public struct WebInspectorFetchedResultsTransaction<ItemID: Hashable & Sendable>: Hashable, Sendable {
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
        if oldSnapshot == newSnapshot {
            self.init(unchangedSnapshot: newSnapshot, updatedItemIDs: updatedItemIDs)
            return
        }
        self.init(
            oldSnapshot: oldSnapshot,
            newSnapshot: newSnapshot,
            isReset: false,
            sectionChanges: Self.sectionChanges(from: oldSnapshot, to: newSnapshot),
            itemChanges: Self.itemChanges(from: oldSnapshot, to: newSnapshot, updatedItemIDs: updatedItemIDs)
        )
    }

    init(
        unchangedSnapshot snapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        updatedItemIDs: Set<ItemID>
    ) {
        // The publisher already proved that identity, order, and section
        // membership are unchanged, so only update positions are meaningful.
        self.init(
            oldSnapshot: snapshot,
            newSnapshot: snapshot,
            isReset: false,
            sectionChanges: [],
            itemChanges: Self.updateChanges(
                in: snapshot,
                updatedItemIDs: updatedItemIDs
            )
        )
    }

    private static func updateChanges(
        in snapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        updatedItemIDs: Set<ItemID>
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        guard updatedItemIDs.isEmpty == false else {
            return []
        }
        var changes: [WebInspectorFetchedResultsItemChange<ItemID>] = []
        changes.reserveCapacity(updatedItemIDs.count)
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            for (itemIndex, itemID) in section.itemIDs.enumerated()
                where updatedItemIDs.contains(itemID) {
                changes.append(.update(
                    itemID: itemID,
                    indexPath: WebInspectorFetchedResultsIndexPath(
                        section: sectionIndex,
                        item: itemIndex
                    )
                ))
            }
        }
        return changes
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

        let oldCommonOrder = oldSnapshot.sectionIDs.filter { newIndexes[$0] != nil }
        let newCommonOrder = newSnapshot.sectionIDs.filter { oldIndexes[$0] != nil }
        let moves: [WebInspectorFetchedResultsSectionChange] = if oldCommonOrder == newCommonOrder {
            []
        } else {
            newSnapshot.sections.enumerated()
                .compactMap { newIndex, section -> WebInspectorFetchedResultsSectionChange? in
                    guard let oldIndex = oldIndexes[section.id], oldIndex != newIndex else {
                        return nil
                    }
                    return .move(sectionID: section.id, from: oldIndex, to: newIndex)
                }
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
            updatedItemIDs: updatedItemIDs,
            excludedItemIDs: Set(sectionMembershipChanges.map(itemID))
        )

        let updates = newSnapshot.itemIDs.compactMap { itemID -> WebInspectorFetchedResultsItemChange<ItemID>? in
            guard updatedItemIDs.contains(itemID),
                  let oldPosition = oldPositions[itemID],
                  let newPosition = newPositions[itemID],
                  oldPosition.sectionID == newPosition.sectionID,
                  oldPosition.indexPath == newPosition.indexPath else {
                return nil
            }
            return .update(itemID: itemID, indexPath: newPosition.indexPath)
        }

        return deletes + inserts + sectionMembershipChanges + moves + updates
    }

    private static func sectionMembershipChanges(
        from oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        to newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
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
        from oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        to newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>,
        oldPositions: [ItemID: ItemPosition],
        newPositions: [ItemID: ItemPosition],
        updatedItemIDs: Set<ItemID>,
        excludedItemIDs: Set<ItemID>
    ) -> [WebInspectorFetchedResultsItemChange<ItemID>] {
        let oldCommonOrder = oldSnapshot.itemIDs.filter { newPositions[$0] != nil }
        let newCommonOrder = newSnapshot.itemIDs.filter { oldPositions[$0] != nil }
        guard oldCommonOrder != newCommonOrder else {
            return []
        }

        if updatedItemIDs.count == 1,
           let changedID = updatedItemIDs.first,
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

/// One atomic fetched-results publication.
///
/// The initial value and every later transaction contain a complete identity
/// snapshot. Consumers that observe a revision gap can therefore replace their
/// local snapshot instead of applying a delta across missing revisions.
public enum WebInspectorFetchedResultsUpdate<ItemID: Hashable & Sendable>: Hashable, Sendable {
    /// The complete result state that begins a subscription.
    ///
    /// If the producer advances before first consumption, the pending initial
    /// value coalesces to the newest complete snapshot.
    case initial(
        revision: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    )

    /// One later result publication.
    ///
    /// `reconfigureItemIDs` contains identities present in the new snapshot
    /// whose model-backed presentation changed, including coalesced updates.
    case transaction(
        revision: UInt64,
        transaction: WebInspectorFetchedResultsTransaction<ItemID>,
        reconfigureItemIDs: Set<ItemID>
    )
}

extension WebInspectorFetchedResultsUpdate {
    fileprivate func coalescing(
        _ pending: WebInspectorFetchedResultsUpdate<ItemID>
    ) -> WebInspectorFetchedResultsUpdate<ItemID> {
        switch (pending, self) {
        case (_, .initial):
            return self
        case (.initial, .transaction(let revision, let transaction, _)):
            return .initial(
                revision: revision,
                snapshot: transaction.newSnapshot
            )
        case let (
            .transaction(_, _, pendingReconfigureItemIDs),
            .transaction(revision, transaction, reconfigureItemIDs)
        ):
            return .transaction(
                revision: revision,
                transaction: transaction,
                reconfigureItemIDs: reconfigureItemIDs
                    .union(pendingReconfigureItemIDs)
                    .intersection(transaction.newSnapshot.itemIDs)
            )
        }
    }
}

private final class WebInspectorFetchedResultsUpdateSubscriber<
    ItemID: Hashable & Sendable
>: Sendable {
    typealias Update = WebInspectorFetchedResultsUpdate<ItemID>

    private struct State {
        var pending: Update?
        var waiters: [CheckedContinuation<Update?, Never>] = []
        var isFinished = false
    }

    private struct Resumption {
        var continuation: CheckedContinuation<Update?, Never>
        var update: Update?
    }

    private let state: Mutex<State>
    private let onTermination: @Sendable () -> Void

    init(initial: Update, onTermination: @escaping @Sendable () -> Void) {
        state = Mutex(State(pending: initial))
        self.onTermination = onTermination
    }

    func makeStream() -> AsyncStream<Update> {
        AsyncStream(
            unfolding: { [self] in
                await next()
            },
            onCancel: { [self] in
                finish()
            }
        )
    }

    func offer(_ update: Update) {
        let waiter = state.withLock { state -> CheckedContinuation<Update?, Never>? in
            guard state.isFinished == false else {
                return nil
            }
            if state.waiters.isEmpty == false {
                return state.waiters.removeFirst()
            }
            if let pending = state.pending {
                state.pending = update.coalescing(pending)
            } else {
                state.pending = update
            }
            return nil
        }
        waiter?.resume(returning: update)
    }

    func finish() {
        let resumptions = state.withLock { state -> [Resumption]? in
            guard state.isFinished == false else {
                return nil
            }
            state.isFinished = true

            var resumptions: [Resumption] = []
            if state.waiters.isEmpty == false, let pending = state.pending {
                resumptions.append(Resumption(
                    continuation: state.waiters.removeFirst(),
                    update: pending
                ))
                state.pending = nil
            }
            resumptions.append(contentsOf: state.waiters.map {
                Resumption(continuation: $0, update: nil)
            })
            state.waiters.removeAll(keepingCapacity: false)
            return resumptions
        }
        guard let resumptions else {
            return
        }
        for resumption in resumptions {
            resumption.continuation.resume(returning: resumption.update)
        }
        onTermination()
    }

    private func next() async -> Update? {
        if Task.isCancelled {
            finish()
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate = state.withLock { state -> (shouldResume: Bool, update: Update?) in
                    if let pending = state.pending {
                        state.pending = nil
                        return (true, pending)
                    }
                    if state.isFinished {
                        return (true, nil)
                    }
                    state.waiters.append(continuation)
                    return (false, nil)
                }
                if immediate.shouldResume {
                    continuation.resume(returning: immediate.update)
                }
            }
        } onCancel: { [self] in
            finish()
        }
    }

    deinit {
        finish()
    }
}

private final class WeakWebInspectorFetchedResultsUpdateSubscriber<
    ItemID: Hashable & Sendable
> {
    weak var value: WebInspectorFetchedResultsUpdateSubscriber<ItemID>?

    init(_ value: WebInspectorFetchedResultsUpdateSubscriber<ItemID>) {
        self.value = value
    }
}

final class WebInspectorFetchedResultsUpdateBroker<ItemID: Hashable & Sendable>: Sendable {
    typealias Update = WebInspectorFetchedResultsUpdate<ItemID>
    private typealias Subscriber = WebInspectorFetchedResultsUpdateSubscriber<ItemID>

    private struct State {
        var subscribers: [UUID: WeakWebInspectorFetchedResultsUpdateSubscriber<ItemID>] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    func makeStream(initial: Update) -> AsyncStream<Update> {
        let id = UUID()
        let subscriber = Subscriber(initial: initial) { [weak self] in
            self?.removeStream(id)
        }
        let shouldFinish = state.withLock { state in
            guard state.isFinished == false else {
                return true
            }
            state.subscribers = state.subscribers.filter { $0.value.value != nil }
            state.subscribers[id] = WeakWebInspectorFetchedResultsUpdateSubscriber(subscriber)
            return false
        }
        if shouldFinish {
            subscriber.finish()
        }
        return subscriber.makeStream()
    }

    func yield(_ update: Update) {
        let subscribers = state.withLock { state -> [Subscriber] in
            state.subscribers = state.subscribers.filter { $0.value.value != nil }
            return state.subscribers.values.compactMap(\.value)
        }
        for subscriber in subscribers {
            subscriber.offer(update)
        }
    }

    func finish() {
        let subscribers = state.withLock { state -> [Subscriber] in
            guard state.isFinished == false else {
                return []
            }
            state.isFinished = true
            let subscribers = state.subscribers.values.compactMap(\.value)
            state.subscribers.removeAll(keepingCapacity: false)
            return subscribers
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    private func removeStream(_ id: UUID) {
        _ = state.withLock { state in
            state.subscribers.removeValue(forKey: id)
        }
    }

    deinit {
        finish()
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

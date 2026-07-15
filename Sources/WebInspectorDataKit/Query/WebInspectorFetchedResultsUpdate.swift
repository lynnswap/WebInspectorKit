import Foundation

/// A monotonic revision in one fetched-results controller's publication space.
public struct WebInspectorFetchedResultsRevision:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: WebInspectorFetchedResultsRevision,
        rhs: WebInspectorFetchedResultsRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A complete flat membership snapshot.
public struct WebInspectorFetchedResultsSnapshot<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    public let itemIDs: [ItemID]
    private let membership: Set<ItemID>

    public init(itemIDs: [ItemID] = []) {
        self.itemIDs = itemIDs
        membership = Set(itemIDs)
    }

    package func contains(_ itemID: ItemID) -> Bool {
        membership.contains(itemID)
    }
}

/// A structural change between two flat memberships.
public enum WebInspectorFetchedResultsItemChange<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    case insert(itemID: ItemID, at: Int)
    case delete(itemID: ItemID, at: Int)
    case move(itemID: ItemID, from: Int, to: Int)
}

/// One atomic fetched-results publication.
public enum WebInspectorFetchedResultsUpdate<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    case initial(
        revision: WebInspectorFetchedResultsRevision,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    )
    case changes(
        fromRevision: WebInspectorFetchedResultsRevision,
        toRevision: WebInspectorFetchedResultsRevision,
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>],
        updatedItemIDs: Set<ItemID>
    )
    case reset(
        revision: WebInspectorFetchedResultsRevision,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    )
}

package struct WebInspectorFetchedResultsDifference<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    package let itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>]
    package let updatedItemIDs: Set<ItemID>

    package var isEmpty: Bool {
        itemChanges.isEmpty && updatedItemIDs.isEmpty
    }

    package init(
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>] = [],
        updatedItemIDs: Set<ItemID> = []
    ) {
        self.itemChanges = itemChanges
        self.updatedItemIDs = updatedItemIDs
    }
}

package func webInspectorFetchedResultsDifference<ItemID>(
    from oldItemIDs: [ItemID],
    to newItemIDs: [ItemID],
    updatedItemIDs: Set<ItemID>
) -> WebInspectorFetchedResultsDifference<ItemID>
where ItemID: Hashable & Sendable {
    let difference =
        newItemIDs
        .difference(from: oldItemIDs)
        .inferringMoves()
    var deletes: [(offset: Int, itemID: ItemID)] = []
    var inserts: [(offset: Int, itemID: ItemID)] = []
    var moves: [(from: Int, to: Int, itemID: ItemID)] = []

    for change in difference {
        switch change {
        case let .remove(offset, itemID, associatedWith):
            if associatedWith == nil {
                deletes.append((offset, itemID))
            }
        case let .insert(offset, itemID, associatedWith):
            if let oldOffset = associatedWith {
                moves.append((oldOffset, offset, itemID))
            } else {
                inserts.append((offset, itemID))
            }
        }
    }

    deletes.sort { $0.offset > $1.offset }
    inserts.sort { $0.offset < $1.offset }
    moves.sort {
        if $0.to != $1.to { return $0.to < $1.to }
        return $0.from < $1.from
    }

    let changes =
        deletes.map {
            WebInspectorFetchedResultsItemChange.delete(
                itemID: $0.itemID,
                at: $0.offset
            )
        }
        + inserts.map {
            WebInspectorFetchedResultsItemChange.insert(
                itemID: $0.itemID,
                at: $0.offset
            )
        }
        + moves.map {
            WebInspectorFetchedResultsItemChange.move(
                itemID: $0.itemID,
                from: $0.from,
                to: $0.to
            )
        }

    let oldMembership = Set(oldItemIDs)
    let newMembership = Set(newItemIDs)

    return WebInspectorFetchedResultsDifference(
        itemChanges: changes,
        updatedItemIDs:
            updatedItemIDs
            .intersection(oldMembership)
            .intersection(newMembership)
    )
}

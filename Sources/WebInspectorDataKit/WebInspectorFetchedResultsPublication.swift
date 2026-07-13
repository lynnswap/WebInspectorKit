import Foundation

/// Section/item position inside fetched results.
public struct WebInspectorFetchedResultsIndexPath: Hashable, Sendable, Comparable {
    public var section: Int
    public var item: Int

    public init(section: Int, item: Int) {
        self.section = section
        self.item = item
    }

    public static func < (
        lhs: WebInspectorFetchedResultsIndexPath,
        rhs: WebInspectorFetchedResultsIndexPath
    ) -> Bool {
        (lhs.section, lhs.item) < (rhs.section, rhs.item)
    }
}

/// Immutable snapshot of fetched-result section and item identities.
public struct WebInspectorFetchedResultsSnapshot<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    /// One section in a fetched-results snapshot.
    public struct Section: Identifiable, Hashable, Sendable {
        public let name: SectionName
        public var id: SectionName { name }
        public let title: String?
        public let itemIDs: [ItemID]

        package init(
            name: SectionName,
            title: String? = nil,
            itemIDs: [ItemID]
        ) {
            self.name = name
            self.title = title
            self.itemIDs = itemIDs
        }
    }

    private enum Storage: Hashable, Sendable {
        case flat([ItemID])
        case sectioned([Section])
    }

    private let storage: Storage

    package init(sections: [Section]) {
        let itemIDs = sections.flatMap(\.itemIDs)
        precondition(
            Set(itemIDs).count == itemIDs.count,
            "WebInspectorFetchedResultsSnapshot item IDs must be unique."
        )
        let sectionNames = sections.map(\.name)
        precondition(
            Set(sectionNames).count == sectionNames.count,
            "WebInspectorFetchedResultsSnapshot section names must be unique."
        )
        storage = .sectioned(sections)
    }

    /// Creates an unsectioned snapshot from item identities.
    public init(itemIDs: [ItemID] = []) where SectionName == Never {
        precondition(
            Set(itemIDs).count == itemIDs.count,
            "WebInspectorFetchedResultsSnapshot item IDs must be unique."
        )
        storage = .flat(itemIDs)
    }

    public var sections: [Section] {
        switch storage {
        case .flat:
            []
        case let .sectioned(sections):
            sections
        }
    }

    public var sectionNames: [SectionName] {
        sections.map(\.name)
    }

    public var itemIDs: [ItemID] {
        switch storage {
        case let .flat(itemIDs):
            itemIDs
        case let .sectioned(sections):
            sections.flatMap(\.itemIDs)
        }
    }

    public func itemIDs(in sectionName: SectionName) -> [ItemID]? {
        sections.first { $0.name == sectionName }?.itemIDs
    }
}

/// Section-level change in a fetched-results transaction.
public enum WebInspectorFetchedResultsSectionChange<
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    case insert(sectionName: SectionName, index: Int)
    case delete(sectionName: SectionName, index: Int)
    case move(sectionName: SectionName, from: Int, to: Int)
    case update(sectionName: SectionName, index: Int)
}

/// Item-level change in a fetched-results transaction.
public enum WebInspectorFetchedResultsItemChange<
    ItemID: Hashable & Sendable
>: Hashable, Sendable {
    case insert(
        itemID: ItemID,
        indexPath: WebInspectorFetchedResultsIndexPath
    )
    case delete(
        itemID: ItemID,
        indexPath: WebInspectorFetchedResultsIndexPath
    )
    case move(
        itemID: ItemID,
        from: WebInspectorFetchedResultsIndexPath,
        to: WebInspectorFetchedResultsIndexPath
    )
    case update(
        itemID: ItemID,
        indexPath: WebInspectorFetchedResultsIndexPath
    )
}

/// One atomic publication from a generic fetched-results registration.
public enum WebInspectorFetchedResultsUpdate<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    /// The complete state at the subscription boundary.
    case initial(
        revision: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
    )
    /// One contiguous identity and presentation delta.
    case changes(
        fromRevision: UInt64,
        toRevision: UInt64,
        sectionChanges: [
            WebInspectorFetchedResultsSectionChange<SectionName>
        ],
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>],
        updatedItemIDs: Set<ItemID>
    )
    /// A complete owner-atomic replacement after continuity was lost.
    case reset(
        revision: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
    )
}

package struct WebInspectorFetchedResultsChanges<
    ItemID: Hashable & Sendable,
    SectionName: Hashable & Sendable
>: Hashable, Sendable {
    package let sectionChanges: [
        WebInspectorFetchedResultsSectionChange<SectionName>
    ]
    package let itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>]
    package let updatedItemIDs: Set<ItemID>

    package var isEmpty: Bool {
        sectionChanges.isEmpty
            && itemChanges.isEmpty
            && updatedItemIDs.isEmpty
    }

    package init(
        sectionChanges: [
            WebInspectorFetchedResultsSectionChange<SectionName>
        ] = [],
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>] = [],
        updatedItemIDs: Set<ItemID> = []
    ) {
        self.sectionChanges = sectionChanges
        self.itemChanges = itemChanges
        self.updatedItemIDs = updatedItemIDs
    }
}

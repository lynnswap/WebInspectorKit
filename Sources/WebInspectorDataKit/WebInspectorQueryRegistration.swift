import Synchronization

package struct WebInspectorQueryRegistrationID: Hashable, Sendable {
    package var rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package final class WebInspectorQueryRegistrationLifetime: Sendable {
    private let generation = Mutex<UInt64>(0)

    package init() {}

    package func nextGeneration() -> UInt64 {
        generation.withLock { generation in
            precondition(
                generation < UInt64.max,
                "Fetched-results query generation overflowed."
            )
            generation += 1
            return generation
        }
    }

    package func isCurrent(generation expectedGeneration: UInt64) -> Bool {
        generation.withLock { generation in
            generation == expectedGeneration
        }
    }
}

package struct WebInspectorIndexedQueryCursor: Hashable, Sendable {
    package let sourceEpoch: UInt64
    package let sequence: UInt64

    package init(sourceEpoch: UInt64, sequence: UInt64) {
        self.sourceEpoch = sourceEpoch
        self.sequence = sequence
    }
}

package struct WebInspectorIndexedQueryState<ItemID: Hashable & Sendable>: Hashable, Sendable {
    package let cursor: WebInspectorIndexedQueryCursor
    package let snapshot: WebInspectorFetchedResultsSnapshot<ItemID>

    package init(
        cursor: WebInspectorIndexedQueryCursor,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    ) {
        self.cursor = cursor
        self.snapshot = snapshot
    }
}

package enum WebInspectorIndexedQueryChange<ItemID: Hashable & Sendable>: Hashable, Sendable {
    case reset
    case transaction(
        base: WebInspectorIndexedQueryCursor,
        transaction: WebInspectorFetchedResultsTransaction<ItemID>
    )
}

package struct WebInspectorIndexedQueryPublication<ItemID: Hashable & Sendable>: Hashable, Sendable {
    package let state: WebInspectorIndexedQueryState<ItemID>
    package let change: WebInspectorIndexedQueryChange<ItemID>
    package let reconfigureItemIDs: Set<ItemID>

    package init(
        state: WebInspectorIndexedQueryState<ItemID>,
        change: WebInspectorIndexedQueryChange<ItemID>,
        reconfigureItemIDs: Set<ItemID>
    ) {
        self.state = state
        self.change = change
        self.reconfigureItemIDs = reconfigureItemIDs
    }
}

package struct WebInspectorIndexedQueryDelivery<ItemID: Hashable & Sendable>: Hashable, Sendable {
    package let registrationID: WebInspectorQueryRegistrationID
    package let generation: UInt64
    package let publication: WebInspectorIndexedQueryPublication<ItemID>
}

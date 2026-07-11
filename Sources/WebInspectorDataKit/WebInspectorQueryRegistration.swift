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

package struct WebInspectorIndexedQueryProjection<ItemID: Hashable & Sendable>: Sendable {
    package var sourceEpoch: UInt64
    package var sequence: UInt64
    package var snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    package var reconfigureItemIDs: Set<ItemID>
}

package struct WebInspectorIndexedQueryDelivery<ItemID: Hashable & Sendable>: Sendable {
    package var registrationID: WebInspectorQueryRegistrationID
    package var generation: UInt64
    package var projection: WebInspectorIndexedQueryProjection<ItemID>
}

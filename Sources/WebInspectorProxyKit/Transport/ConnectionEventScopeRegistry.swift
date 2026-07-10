import Foundation

struct ConnectionCapabilityKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
}

enum ConnectionCapabilityLeaseOwner: Hashable, Sendable {
    case eventScope(WebInspectorProxyEventScopeID)
    case modelFeed(ConnectionModelFeedID, ModelDomain)
    case modelElementPicker(ConnectionModelFeedID)
}

struct ConnectionEventScopeRegistry {
    struct Entry: Sendable {
        var sink: WebInspectorEventSink?
        var capability: ConnectionCapabilityKey
        var capacity: Int?
    }

    private(set) var entries: [WebInspectorProxyEventScopeID: Entry] = [:]

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func insert(
        _ sink: WebInspectorEventSink,
        capability: ConnectionCapabilityKey,
        capacity: Int?,
        generation: WebInspectorPage.Generation
    ) {
        precondition(entries[sink.id] == nil, "Duplicate Web Inspector event scope identifier.")
        entries[sink.id] = Entry(sink: sink, capability: capability, capacity: capacity)
        handleInitialDelivery(sink.yieldReset(generation), id: sink.id, capacity: capacity)
    }

    mutating func remove(_ id: WebInspectorProxyEventScopeID) -> Entry? {
        entries.removeValue(forKey: id)
    }

    func sinks(for domain: WebInspectorProxyEventDomain) -> [WebInspectorEventSink] {
        entries.values.compactMap { entry in
            guard entry.sink?.domain == domain else {
                return nil
            }
            return entry.sink
        }
    }

    mutating func markTerminated(_ id: WebInspectorProxyEventScopeID) {
        entries[id]?.sink = nil
    }

    mutating func publishReset(
        _ generation: WebInspectorPage.Generation,
        where predicate: (WebInspectorEventSink) -> Bool
    ) {
        for (id, entry) in Array(entries) {
            guard let sink = entry.sink, predicate(sink) else {
                continue
            }
            handleDelivery(sink.yieldReset(generation), id: id, capacity: entry.capacity)
        }
    }

    mutating func finishSubscribers(with error: (any Error)?) {
        finishSubscribers(where: { _ in true }, with: error)
    }

    mutating func finishSubscribers(
        where predicate: (WebInspectorEventSink) -> Bool,
        with error: (any Error)?
    ) {
        for (id, entry) in Array(entries) {
            guard let sink = entry.sink, predicate(sink) else {
                continue
            }
            sink.finish(error)
            entries[id]?.sink = nil
        }
    }

    mutating func finishAndRemoveAll(with error: (any Error)? = nil) {
        finishSubscribers(with: error)
        entries.removeAll()
    }

    mutating func handleDelivery(
        _ result: WebInspectorEventDeliveryResult,
        id: WebInspectorProxyEventScopeID,
        capacity: Int?
    ) {
        switch result {
        case .enqueued:
            break
        case .dropped:
            guard let capacity else {
                preconditionFailure("An unbounded Web Inspector event stream dropped an event.")
            }
            entries[id]?.sink?.finish(WebInspectorProxyError.eventBufferOverflow(capacity: capacity))
            entries[id]?.sink = nil
        case .terminated:
            entries[id]?.sink = nil
        case .mismatchedEvent:
            // ConnectionCore owns these connection-terminal failures because
            // it also owns ingress ordering and all peer subscribers.
            break
        }
    }

    private mutating func handleInitialDelivery(
        _ result: WebInspectorEventDeliveryResult,
        id: WebInspectorProxyEventScopeID,
        capacity: Int?
    ) {
        switch result {
        case .enqueued:
            break
        case .terminated:
            entries[id]?.sink = nil
        case .dropped:
            preconditionFailure("The initial reset did not fit in an empty event buffer of capacity \(capacity ?? -1).")
        case .mismatchedEvent:
            preconditionFailure("An initial reset cannot decode a protocol event.")
        }
    }
}

struct ConnectionCapabilityRegistry {
    enum PhysicalState: Sendable {
        case inactive(generation: WebInspectorPage.Generation)
        case enabling(
            generation: WebInspectorPage.Generation,
            operationID: UInt64,
            mustDisableAfterEnable: Bool
        )
        case enabled(generation: WebInspectorPage.Generation)
        case disabling(generation: WebInspectorPage.Generation, operationID: UInt64)

        var generation: WebInspectorPage.Generation {
            switch self {
            case let .inactive(generation),
                 let .enabling(generation, _, _),
                 let .enabled(generation),
                 let .disabling(generation, _):
                generation
            }
        }
    }

    struct State: Sendable {
        var physical: PhysicalState
        var leaseOwners: Set<ConnectionCapabilityLeaseOwner> = []
        var failedLeaseOwners: Set<ConnectionCapabilityLeaseOwner> = []
        var activatedLeaseOwners: Set<ConnectionCapabilityLeaseOwner> = []
        var activationWaiters: [ConnectionCapabilityLeaseOwner: ReplyPromise<Void>] = [:]
        var releaseWaiters: [ConnectionCapabilityLeaseOwner: ReplyPromise<Void>] = [:]

        var desiredLeaseOwners: Set<ConnectionCapabilityLeaseOwner> {
            leaseOwners.subtracting(failedLeaseOwners)
        }

        var desiredCount: Int {
            desiredLeaseOwners.count
        }

        var hasActivatedDesiredLease: Bool {
            !activatedLeaseOwners.intersection(desiredLeaseOwners).isEmpty
        }
    }

    var states: [ConnectionCapabilityKey: State] = [:]
    private var nextOperationID: UInt64 = 0

    mutating func allocateOperationID() -> UInt64 {
        nextOperationID &+= 1
        return nextOperationID
    }

    mutating func removeEmptyState(for key: ConnectionCapabilityKey) {
        guard let state = states[key],
              state.leaseOwners.isEmpty,
              state.activationWaiters.isEmpty,
              state.releaseWaiters.isEmpty else {
            return
        }
        if case .inactive = state.physical {
            states.removeValue(forKey: key)
        }
    }
}

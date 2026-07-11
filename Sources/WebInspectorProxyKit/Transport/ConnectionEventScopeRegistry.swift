import Foundation

struct ConnectionCapabilityKey: Hashable, Sendable {
    var route: RoutingTargetID
    var targetID: WebInspectorTarget.ID
    var domain: WebInspectorProxyEventDomain
}

enum ConnectionCapabilityActivationPlan {
    static func domains(
        for requestedDomains: [WebInspectorProxyEventDomain],
        includePageDependencyForCSS: Bool
    ) -> [WebInspectorProxyEventDomain] {
        var seen: Set<WebInspectorProxyEventDomain> = []
        var result: [WebInspectorProxyEventDomain] = []
        for requestedDomain in requestedDomains {
            for domain in dependencies(
                for: requestedDomain,
                includePageDependencyForCSS: includePageDependencyForCSS
            ) {
                if seen.insert(domain).inserted {
                    result.append(domain)
                }
            }
        }
        return result
    }

    private static func dependencies(
        for domain: WebInspectorProxyEventDomain,
        includePageDependencyForCSS: Bool
    ) -> [WebInspectorProxyEventDomain] {
        switch domain {
        case .css where includePageDependencyForCSS:
            // WebKit 624's InspectorStyleSheet retains the enabled Page
            // agent and dereferences it while publishing stylesheet headers.
            // Keep Page enabled for the entire CSS capability lifetime. Newer
            // WebKit revisions no longer require this on page targets, but
            // preserve the protocol domain and accept the same ordering.
            // Frame targets use FrameCSSAgent and may not expose Page at all.
            [.page, .css]
        default:
            [domain]
        }
    }
}

enum ConnectionCapabilityLeaseOwner: Hashable, Sendable {
    case eventScope(WebInspectorProxyEventScopeID)
    case modelFeed(ConnectionModelFeedID, ModelDomain)
    case modelElementPicker(ConnectionModelFeedID)
}

struct ConnectionEventScopeRegistry {
    struct Entry: Sendable {
        var sink: WebInspectorEventSink?
        var capabilities: [ConnectionCapabilityKey]
        var capacity: Int?
    }

    private(set) var entries: [WebInspectorProxyEventScopeID: Entry] = [:]

    var isEmpty: Bool {
        entries.isEmpty
    }

    mutating func insert(
        _ sink: WebInspectorEventSink,
        capacity: Int?,
        generation: WebInspectorPage.Generation
    ) {
        precondition(entries[sink.id] == nil, "Duplicate Web Inspector event scope identifier.")
        entries[sink.id] = Entry(sink: sink, capabilities: [], capacity: capacity)
        handleInitialDelivery(sink.yieldReset(generation), id: sink.id, capacity: capacity)
    }

    mutating func appendCapability(
        _ capability: ConnectionCapabilityKey,
        to id: WebInspectorProxyEventScopeID
    ) {
        guard var entry = entries[id] else {
            preconditionFailure("A Web Inspector event scope lost its registration during capability acquisition.")
        }
        precondition(
            !entry.capabilities.contains(capability),
            "A Web Inspector event scope acquired the same capability twice."
        )
        entry.capabilities.append(capability)
        entries[id] = entry
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
        /// The target is known, but an in-flight or previously enabled
        /// physical agent prevents us from claiming either wire state.
        /// Reconciliation must establish the domain-specific postcondition
        /// before activating this logical generation.
        case unknown(generation: WebInspectorPage.Generation)
        /// The physical agent remains enabled, but its model state has not
        /// yet been rebuilt for the newly bound logical generation.
        case replayRequired(generation: WebInspectorPage.Generation)
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
                 let .unknown(generation),
                 let .replayRequired(generation),
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

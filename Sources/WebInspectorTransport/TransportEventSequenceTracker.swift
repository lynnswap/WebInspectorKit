struct TransportEventSequenceSnapshot: Equatable, Sendable {
    var sequence: UInt64
    var receivedDomainSequences: [ProtocolDomain: UInt64]
}

struct TransportEventSequenceTracker: Equatable, Sendable {
    private var nextSequence: UInt64 = 0
    private var lastSequenceByDomain: [ProtocolDomain: UInt64] = [:]

    var current: TransportEventSequenceSnapshot {
        TransportEventSequenceSnapshot(
            sequence: nextSequence,
            receivedDomainSequences: lastSequenceByDomain
        )
    }

    mutating func recordEvent(domain: ProtocolDomain) -> TransportEventSequenceSnapshot {
        nextSequence &+= 1
        lastSequenceByDomain[domain] = nextSequence
        return current
    }
}

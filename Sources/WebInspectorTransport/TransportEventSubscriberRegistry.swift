struct TransportEventSubscriberRegistry {
    typealias Continuation = AsyncStream<ProtocolEventEnvelope>.Continuation

    private var nextSubscriberID: UInt64 = 0
    private var domainSubscribers: [ProtocolDomain: [UInt64: Continuation]] = [:]
    private var orderedSubscribers: [UInt64: Continuation] = [:]

    mutating func insert(_ continuation: Continuation, domain: ProtocolDomain) -> UInt64 {
        nextSubscriberID &+= 1
        let subscriberID = nextSubscriberID
        domainSubscribers[domain, default: [:]][subscriberID] = continuation
        return subscriberID
    }

    mutating func insertOrdered(_ continuation: Continuation) -> UInt64 {
        nextSubscriberID &+= 1
        let subscriberID = nextSubscriberID
        orderedSubscribers[subscriberID] = continuation
        return subscriberID
    }

    func continuations(for domain: ProtocolDomain) -> [Continuation] {
        domainSubscribers[domain].map { Array($0.values) } ?? []
    }

    var orderedContinuations: [Continuation] {
        Array(orderedSubscribers.values)
    }

    mutating func remove(_ subscriberID: UInt64, domain: ProtocolDomain) {
        domainSubscribers[domain]?.removeValue(forKey: subscriberID)
        if domainSubscribers[domain]?.isEmpty == true {
            domainSubscribers.removeValue(forKey: domain)
        }
    }

    mutating func removeOrdered(_ subscriberID: UInt64) {
        orderedSubscribers.removeValue(forKey: subscriberID)
    }

    mutating func finishAndRemoveAll() {
        for continuations in domainSubscribers.values {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        for continuation in orderedSubscribers.values {
            continuation.finish()
        }
        domainSubscribers.removeAll()
        orderedSubscribers.removeAll()
    }
}

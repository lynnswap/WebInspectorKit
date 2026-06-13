struct TransportMainPageTargetWaiter: Sendable {
    var id: UInt64
    var promise: ReplyPromise<TransportMainPageTarget>
}

struct TransportMainPageTargetWaiterStore: Sendable {
    private var nextWaiterID: UInt64 = 0
    private var waitersByID: [UInt64: ReplyPromise<TransportMainPageTarget>] = [:]

    var isEmpty: Bool {
        waitersByID.isEmpty
    }

    mutating func insert() -> TransportMainPageTargetWaiter {
        nextWaiterID &+= 1
        let id = nextWaiterID
        let promise = ReplyPromise<TransportMainPageTarget>()
        waitersByID[id] = promise
        return TransportMainPageTargetWaiter(id: id, promise: promise)
    }

    @discardableResult
    mutating func remove(id: UInt64) -> ReplyPromise<TransportMainPageTarget>? {
        waitersByID.removeValue(forKey: id)
    }

    mutating func removeAll() -> [ReplyPromise<TransportMainPageTarget>] {
        let waiters = Array(waitersByID.values)
        waitersByID.removeAll()
        return waiters
    }
}

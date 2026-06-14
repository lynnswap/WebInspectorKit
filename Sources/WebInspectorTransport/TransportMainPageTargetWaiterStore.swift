extension TransportSession {
    struct MainPageTargetWaiter: Sendable {
        var id: UInt64
        var promise: ReplyPromise<MainPageTarget>
    }

    struct MainPageTargetWaiterStore: Sendable {
        private var nextWaiterID: UInt64 = 0
        private var waitersByID: [UInt64: ReplyPromise<MainPageTarget>] = [:]

        var isEmpty: Bool {
            waitersByID.isEmpty
        }

        mutating func insert() -> MainPageTargetWaiter {
            nextWaiterID &+= 1
            let id = nextWaiterID
            let promise = ReplyPromise<MainPageTarget>()
            waitersByID[id] = promise
            return MainPageTargetWaiter(id: id, promise: promise)
        }

        @discardableResult
        mutating func remove(id: UInt64) -> ReplyPromise<MainPageTarget>? {
            waitersByID.removeValue(forKey: id)
        }

        mutating func removeAll() -> [ReplyPromise<MainPageTarget>] {
            let waiters = Array(waitersByID.values)
            waitersByID.removeAll()
            return waiters
        }
    }
}

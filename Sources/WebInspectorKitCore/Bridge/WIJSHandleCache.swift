import Foundation

@MainActor
package final class WIJSHandleCache {
    private let capacity: Int
    private var storage: [Int: AnyObject] = [:]
    private var usageOrder: [Int] = []

    package init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    package func handle(for nodeID: Int) -> AnyObject? {
        guard let handle = storage[nodeID] else {
            return nil
        }
        touch(nodeID)
        return handle
    }

    package func store(handle: AnyObject, for nodeID: Int) {
        storage[nodeID] = handle
        touch(nodeID)
        evictIfNeeded()
    }

    package func removeHandle(for nodeID: Int) {
        storage[nodeID] = nil
        usageOrder.removeAll(where: { $0 == nodeID })
    }

    package func clear() {
        storage.removeAll()
        usageOrder.removeAll()
    }
}

private extension WIJSHandleCache {
    func touch(_ nodeID: Int) {
        usageOrder.removeAll(where: { $0 == nodeID })
        usageOrder.append(nodeID)
    }

    func evictIfNeeded() {
        while usageOrder.count > capacity {
            let evictedNodeID = usageOrder.removeFirst()
            storage[evictedNodeID] = nil
        }
    }
}

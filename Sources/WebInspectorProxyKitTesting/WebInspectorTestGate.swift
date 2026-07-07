import Foundation

public actor WebInspectorTestGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>]

    public init() {
        isOpen = false
        waiters = []
    }

    public func wait() async {
        guard isOpen == false else {
            return
        }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    public func open() async {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

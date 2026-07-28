import Foundation

/// Async gate used to hold and release test backend commands.
public actor WebInspectorTestGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>]

    /// Creates a closed gate.
    public init() {
        isOpen = false
        waiters = []
    }

    /// Suspends until the gate is opened.
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

    /// Opens the gate and resumes all current waiters.
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

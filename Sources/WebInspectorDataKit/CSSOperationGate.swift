import Foundation
import WebInspectorProxyKit

/// Serializes CSS style reads and mutations per target.
actor CSSOperationGate {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var acquiredTargetIDs: Set<WebInspectorTarget.ID> = []
    private var waitersByTargetID: [WebInspectorTarget.ID: [UInt64: Waiter]] = [:]
    private var waiterOrderByTargetID: [WebInspectorTarget.ID: [UInt64]] = [:]
    private var nextWaiterID: UInt64 = 0
    #if DEBUG
    private struct QueueCountWaiter {
        let count: Int
        let promise: ReplyPromise<Void>
    }
    private var queueCountWaiters: [WebInspectorTarget.ID: [QueueCountWaiter]] = [:]
    #endif

    func acquire(targetID: WebInspectorTarget.ID) async throws {
        try Task.checkCancellation()
        if acquiredTargetIDs.insert(targetID).inserted {
            return
        }

        nextWaiterID += 1
        let waiterID = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waitersByTargetID[targetID, default: [:]][waiterID] = Waiter(
                    continuation: continuation
                )
                waiterOrderByTargetID[targetID, default: []].append(waiterID)
                #if DEBUG
                resolveQueueCountWaiters(for: targetID)
                #endif
            }
        } onCancel: {
            Task {
                await self.cancel(targetID: targetID, waiterID: waiterID)
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            // A release can hand this waiter ownership before the cancellation
            // handler removes it. Return that ownership before surfacing the
            // cancellation so the next queued operation cannot deadlock.
            release(targetID: targetID)
            throw error
        }
    }

    func release(targetID: WebInspectorTarget.ID) {
        precondition(
            acquiredTargetIDs.contains(targetID),
            "CSS operation gate released without an owner."
        )
        while let waiterID = waiterOrderByTargetID[targetID]?.first {
            waiterOrderByTargetID[targetID]?.removeFirst()
            guard let waiter = waitersByTargetID[targetID]?.removeValue(forKey: waiterID) else {
                continue
            }
            waiter.continuation.resume(returning: ())
            return
        }
        waiterOrderByTargetID[targetID] = nil
        waitersByTargetID[targetID] = nil
        acquiredTargetIDs.remove(targetID)
    }

    #if DEBUG
    private enum QueueWaitError: Error {
        case timedOut
    }

    func waitForQueuedOperationCount(_ count: Int, for targetID: WebInspectorTarget.ID) async throws {
        guard (waitersByTargetID[targetID]?.count ?? 0) < count else {
            return
        }
        let promise = ReplyPromise<Void>()
        queueCountWaiters[targetID, default: []].append(QueueCountWaiter(count: count, promise: promise))
        defer {
            queueCountWaiters[targetID]?.removeAll { $0.promise === promise }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await promise.value() }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw QueueWaitError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func resolveQueueCountWaiters(for targetID: WebInspectorTarget.ID) {
        let count = waitersByTargetID[targetID]?.count ?? 0
        let ready = (queueCountWaiters[targetID] ?? []).filter { $0.count <= count }
        queueCountWaiters[targetID]?.removeAll { $0.count <= count }
        for waiter in ready {
            waiter.promise.fulfill(.success(()))
        }
    }
    #endif

    private func cancel(targetID: WebInspectorTarget.ID, waiterID: UInt64) {
        waitersByTargetID[targetID]?.removeValue(forKey: waiterID)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

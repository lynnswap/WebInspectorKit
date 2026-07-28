import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

private enum ReplyPromiseTestError: Error, Equatable {
    case duplicate
}

private final class ReplyPromiseLifetimeToken: Sendable {}

@Test
func replyPromiseReplaysFulfillmentBeforeWait() async throws {
    let promise = ReplyPromise<Int>()

    #expect(promise.fulfill(.success(41)))
    #expect(try await promise.value() == 41)
    #expect(try await promise.value() == 41)
    #expect(promise.bookkeepingCountForTesting() == 0)
}

@Test
func replyPromiseResumesConcurrentWaitersWithOneTerminalResult() async throws {
    let promise = ReplyPromise<Int>()
    let first = Task { try await promise.value() }
    let second = Task { try await promise.value() }

    #expect(await waitForReplyPromiseWaiterCount(2, in: promise))
    #expect(promise.fulfill(.success(42)))
    #expect(try await first.value == 42)
    #expect(try await second.value == 42)
    #expect(promise.bookkeepingCountForTesting() == 0)
}

@Test
func replyPromiseKeepsAndReplaysFirstTerminalFailure() async {
    let promise = ReplyPromise<Int>()

    #expect(promise.fulfill(.failure(ReplyPromiseTestError.duplicate)))
    #expect(!promise.fulfill(.success(43)))
    await #expect(throws: ReplyPromiseTestError.duplicate) {
        try await promise.value()
    }
    await #expect(throws: ReplyPromiseTestError.duplicate) {
        try await promise.value()
    }
    #expect(promise.bookkeepingCountForTesting() == 0)
}

@Test
func replyPromiseUnresolvedWaitObservesPreexistingCancellation() async throws {
    let promise = ReplyPromise<Int>()
    let startGate = WebInspectorCancellationAwareTestGate()
    let waiter = Task {
        await startGate.wait()
        return try await promise.value()
    }

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
        try await waiter.value
    }
    #expect(promise.bookkeepingCountForTesting() == 0)
    #expect(promise.fulfill(.success(44)))
    #expect(try await promise.value() == 44)
}

@Test
func replyPromiseCancelledWaiterDoesNotPoisonLaterFulfillment() async throws {
    let promise = ReplyPromise<Int>()
    let cancelledWaiter = Task { try await promise.value() }

    #expect(await waitForReplyPromiseWaiterCount(1, in: promise))
    cancelledWaiter.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWaiter.value
    }
    #expect(promise.bookkeepingCountForTesting() == 0)

    let laterWaiter = Task { try await promise.value() }
    #expect(await waitForReplyPromiseWaiterCount(1, in: promise))
    #expect(promise.fulfill(.success(45)))
    #expect(try await laterWaiter.value == 45)
    #expect(promise.bookkeepingCountForTesting() == 0)
}

@Test
func replyPromiseTerminalResultWinsCancellationAfterFulfillment() async throws {
    let promise = ReplyPromise<Int>()
    let startGate = WebInspectorCancellationAwareTestGate()
    #expect(promise.fulfill(.success(46)))

    let waiter = Task {
        await startGate.wait()
        return try await promise.value()
    }
    waiter.cancel()

    #expect(try await waiter.value == 46)
    #expect(promise.bookkeepingCountForTesting() == 0)
}

@Test
func replyPromiseCancellationAndFulfillmentRaceResumesExactlyOnce() async throws {
    for value in 0..<100 {
        let promise = ReplyPromise<Int>()
        let raceGate = WebInspectorCancellationAwareTestGate()
        let waiter = Task { try await promise.value() }
        #expect(await waitForReplyPromiseWaiterCount(1, in: promise))

        let cancellation = Task {
            await raceGate.wait()
            waiter.cancel()
        }
        let fulfillment = Task {
            await raceGate.wait()
            return promise.fulfill(.success(value))
        }
        await raceGate.open()
        await cancellation.value
        #expect(await fulfillment.value)

        do {
            let result = try await waiter.value
            #expect(result == value)
        } catch is CancellationError {
            // Either terminal outcome may win its independent linearization point.
        } catch {
            Issue.record("Unexpected ReplyPromise race error: \(error)")
        }
        #expect(try await promise.value() == value)
        #expect(promise.bookkeepingCountForTesting() == 0)
    }
}

@Test
func replyPromiseAndPendingTaskReleaseAfterExplicitTerminal() async throws {
    weak var weakPromise: ReplyPromise<Int>?
    weak var weakTaskToken: ReplyPromiseLifetimeToken?

    do {
        let promise = ReplyPromise<Int>()
        let taskToken = ReplyPromiseLifetimeToken()
        weakPromise = promise
        weakTaskToken = taskToken
        let waiter = Task {
            let value = try await promise.value()
            withExtendedLifetime(taskToken) {}
            return value
        }
        #expect(await waitForReplyPromiseWaiterCount(1, in: promise))

        #expect(promise.fulfill(.success(47)))
        #expect(try await waiter.value == 47)
    }

    for _ in 0..<10_000 {
        guard weakPromise != nil || weakTaskToken != nil else {
            break
        }
        await Task.yield()
    }
    #expect(weakPromise == nil)
    #expect(weakTaskToken == nil)
}

private func waitForReplyPromiseWaiterCount<Value: Sendable>(
    _ expectedCount: Int,
    in promise: ReplyPromise<Value>
) async -> Bool {
    for _ in 0..<10_000 {
        if promise.waiterCountForTesting() == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}

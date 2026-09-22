import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

private enum ReplyPromiseTestError: Error, Equatable {
    case duplicate
}

private final class ReplyPromiseLifetimeToken: Sendable {
    let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit { onDeinit() }
}

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
    let first = await registeredWaiter(in: promise)
    let second = await registeredWaiter(in: promise)
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
    let cancelledWaiter = await registeredWaiter(in: promise)
    cancelledWaiter.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWaiter.value
    }
    #expect(promise.bookkeepingCountForTesting() == 0)

    let laterWaiter = await registeredWaiter(in: promise)
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
        let waiter = await registeredWaiter(in: promise)

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
    let promiseRelease = AsyncStream<Void>.makeStream()
    let taskRelease = AsyncStream<Void>.makeStream()
    defer {
        promiseRelease.continuation.finish()
        taskRelease.continuation.finish()
    }

    do {
        let promise = ReplyPromise<ReplyPromiseLifetimeToken>()
        let taskToken = ReplyPromiseLifetimeToken { taskRelease.continuation.yield(()) }
        let registration = AsyncStream<Void>.makeStream()
        let waiter = Task {
            let value = try await promise.value {
                registration.continuation.yield(())
            }
            withExtendedLifetime(taskToken) {}
            return value
        }
        var registrations = registration.stream.makeAsyncIterator()
        _ = await registrations.next()
        registration.continuation.finish()

        // The resolved value remains owned by the promise and the task result.
        // Its deinit proves that both terminal owners released it.
        #expect(promise.fulfill(.success(ReplyPromiseLifetimeToken {
            promiseRelease.continuation.yield(())
        })))
        _ = try await waiter.value
    }

    var promiseReleases = promiseRelease.stream.makeAsyncIterator()
    var taskReleases = taskRelease.stream.makeAsyncIterator()
    #expect(await promiseReleases.next() != nil)
    #expect(await taskReleases.next() != nil)
}

private func registeredWaiter<Value: Sendable>(
    in promise: ReplyPromise<Value>
) async -> Task<Value, any Error> {
    let registration = AsyncStream<Void>.makeStream()
    let waiter = Task {
        try await promise.value { registration.continuation.yield(()) }
    }
    var iterator = registration.stream.makeAsyncIterator()
    _ = await iterator.next()
    registration.continuation.finish()
    return waiter
}

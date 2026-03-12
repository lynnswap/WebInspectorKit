import Foundation
import ObservationBridge
import Synchronization
#if canImport(WebKit)
import WebKit
#endif

public actor AsyncValueQueue<Value: Sendable> {
    private var values: [Value] = []
    private var waiters: [CheckedContinuation<Value, Never>] = []

    public init() {}

    public func push(_ value: Value) {
        if waiters.isEmpty {
            values.append(value)
            return
        }

        let waiter = waiters.removeFirst()
        waiter.resume(returning: value)
    }

    public func next() async -> Value {
        if values.isEmpty == false {
            return values.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func next(
        where predicate: @escaping @Sendable (Value) -> Bool
    ) async -> Value {
        while true {
            let value = await next()
            if predicate(value) {
                return value
            }
        }
    }

    public func snapshot() -> [Value] {
        values
    }

    public func drain() -> [Value] {
        let drained = values
        values.removeAll(keepingCapacity: false)
        return drained
    }
}

public actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }

    public func reset() {
        isOpen = false
    }

    public func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

public actor AsyncExclusiveLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        guard waiters.isEmpty == false else {
            isHeld = false
            return
        }

        let waiter = waiters.removeFirst()
        waiter.resume()
    }
}

public actor AsyncCounter {
    private var value = 0
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    @discardableResult
    public func increment() -> Int {
        value += 1
        let readyContinuations = waiters
            .filter { $0.threshold <= value }
            .map(\.continuation)
        waiters.removeAll { $0.threshold <= value }
        for continuation in readyContinuations {
            continuation.resume()
        }
        return value
    }

    public func snapshot() -> Int {
        value
    }

    public func wait(untilAtLeast threshold: Int) async {
        guard value < threshold else {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((threshold, continuation))
        }
    }
}

@MainActor
public final class ObservationRecorder<Value: Sendable> {
    private let queue = AsyncValueQueue<Value>()
    private var handles: Set<ObservationHandle> = []

    public init() {}

    public func record(
        _ registration: (@escaping @MainActor (Value) -> Void) -> ObservationHandle
    ) {
        registration { [queue] value in
            Task {
                await queue.push(value)
            }
        }
        .store(in: &handles)
    }

    public func next() async -> Value {
        await queue.next()
    }

    public func next(
        where predicate: @escaping @Sendable (Value) -> Bool
    ) async -> Value {
        await queue.next(where: predicate)
    }

    public func snapshot() async -> [Value] {
        await queue.snapshot()
    }
}

public final class TestClock: Clock, @unchecked Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration

    private struct SleepWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SuspensionWaiter {
        let minimumSleepers: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
        var suspensionWaiters: [UInt64: SuspensionWaiter] = [:]
        var nextSuspensionToken: UInt64 = 0
    }

    private let state: Mutex<State>

    public var now: Instant {
        state.withLock { $0.now }
    }

    public var minimumResolution: Duration {
        .nanoseconds(1)
    }

    public init(now: Instant = ContinuousClock().now) {
        state = Mutex(State(now: now))
    }

    public func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
        if deadline <= now {
            return
        }
        try Task.checkCancellation()

        let sleepToken = state.withLock { state in
            let token = state.nextSleepToken
            state.nextSleepToken &+= 1
            return token
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let suspensionContinuations = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                    if deadline <= state.now {
                        continuation.resume(returning: ())
                        return []
                    }

                    state.sleepers[sleepToken] = SleepWaiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return Self.popReadySuspensionWaiters(state: &state)
                }
                for suspensionContinuation in suspensionContinuations {
                    suspensionContinuation.resume()
                }
            }
        } onCancel: {
            let cancellationContinuation: CheckedContinuation<Void, Error>? = state.withLock { state in
                state.sleepers.removeValue(forKey: sleepToken)?.continuation
            }
            cancellationContinuation?.resume(throwing: CancellationError())
        }
    }

    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "duration must be non-negative")

        let readyContinuations = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            state.now = state.now.advanced(by: duration)
            let readySleepTokens = state.sleepers.compactMap { token, waiter in
                waiter.deadline <= state.now ? token : nil
            }
            return readySleepTokens.compactMap { token in
                state.sleepers.removeValue(forKey: token)?.continuation
            }
        }

        for continuation in readyContinuations {
            continuation.resume(returning: ())
        }
    }

    public func sleep(untilSuspendedBy minimumSleepers: Int = 1) async {
        precondition(minimumSleepers > 0, "minimumSleepers must be positive")

        let suspensionToken = state.withLock { state in
            let token = state.nextSuspensionToken
            state.nextSuspensionToken &+= 1
            return token
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = state.withLock { state in
                    if state.sleepers.count >= minimumSleepers {
                        return true
                    }

                    state.suspensionWaiters[suspensionToken] = SuspensionWaiter(
                        minimumSleepers: minimumSleepers,
                        continuation: continuation
                    )
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let cancellationContinuation = state.withLock { state in
                state.suspensionWaiters.removeValue(forKey: suspensionToken)?.continuation
            }
            cancellationContinuation?.resume()
        }
    }

    private static func popReadySuspensionWaiters(
        state: inout State
    ) -> [CheckedContinuation<Void, Never>] {
        let readyTokens = state.suspensionWaiters.compactMap { token, waiter in
            waiter.minimumSleepers <= state.sleepers.count ? token : nil
        }

        return readyTokens.compactMap { token in
            state.suspensionWaiters.removeValue(forKey: token)?.continuation
        }
    }
}

private let webKitTestIsolationLock = AsyncExclusiveLock()

@MainActor
public func acquireWebKitTestIsolation() async {
    await webKitTestIsolationLock.acquire()
}

@MainActor
public func releaseWebKitTestIsolation() async {
    await webKitTestIsolationLock.release()
}

@MainActor
public func withWebKitTestIsolation<T>(
    _ body: @MainActor () async throws -> T
) async rethrows -> T {
    await acquireWebKitTestIsolation()
    do {
        let result = try await body()
        await releaseWebKitTestIsolation()
        return result
    } catch {
        await releaseWebKitTestIsolation()
        throw error
    }
}

#if canImport(WebKit)
@MainActor
public func makeIsolatedTestWebViewConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return configuration
}

@MainActor
public func makeIsolatedTestWebView(frame: CGRect = .zero) -> WKWebView {
    WKWebView(frame: frame, configuration: makeIsolatedTestWebViewConfiguration())
}
#endif

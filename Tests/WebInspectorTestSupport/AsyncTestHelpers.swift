import Foundation

public enum TestTimeoutError: Error {
    case timedOut(seconds: Double)
}

public func withTimeout<T: Sendable>(
    seconds: Double = 5,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw TestTimeoutError.timedOut(seconds: seconds)
        }

        guard let first = try await group.next() else {
            throw TestTimeoutError.timedOut(seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}

public func valueWithinTimeout<T: Sendable>(
    seconds: Double = 5,
    _ operation: @Sendable @escaping () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

import Foundation

extension Task where Failure == Never {
    @discardableResult
    package static func immediateIfAvailable(
        priority: TaskPriority? = nil,
        @_inheritActorContext operation: sending @escaping @isolated(any) @Sendable () async -> Success
    ) -> Task<Success, Failure> {
        if #available(iOS 26.0, macOS 26.0, *) {
            return Task.immediate(priority: priority, operation: operation)
        }

        return Task(priority: priority, operation: operation)
    }
}

extension Task where Failure == Error {
    @discardableResult
    package static func immediateIfAvailable(
        priority: TaskPriority? = nil,
        @_inheritActorContext operation: sending @escaping @isolated(any) @Sendable () async throws -> Success
    ) -> Task<Success, Failure> {
        if #available(iOS 26.0, macOS 26.0, *) {
            return Task.immediate(priority: priority, operation: operation)
        }

        return Task(priority: priority, operation: operation)
    }
}

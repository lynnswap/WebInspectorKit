#if canImport(UIKit)
package protocol NetworkListSnapshotBuildExecuting: Sendable {
    func execute<Output: Sendable>(
        _ operation: @escaping @Sendable () -> Output
    ) async -> Output
}

package struct NetworkListDetachedSnapshotBuildExecutor: NetworkListSnapshotBuildExecuting {
    package init() {}

    package func execute<Output: Sendable>(
        _ operation: @escaping @Sendable () -> Output
    ) async -> Output {
        await Task.detached(priority: .userInitiated, operation: operation).value
    }
}
#endif

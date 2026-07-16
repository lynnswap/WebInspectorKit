#if canImport(UIKit)
@MainActor
package protocol NetworkListSnapshotApplyCompletionScheduling: AnyObject {
    func schedule(_ completion: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
package final class NetworkListImmediateSnapshotApplyCompletionScheduler:
    NetworkListSnapshotApplyCompletionScheduling
{
    package init() {}

    package func schedule(_ completion: @escaping @MainActor @Sendable () -> Void) {
        completion()
    }
}
#endif

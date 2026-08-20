#if canImport(UIKit)
@MainActor
protocol NetworkListSnapshotApplyCompletionScheduling: AnyObject {
    func schedule(_ completion: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
final class NetworkListImmediateSnapshotApplyCompletionScheduler:
    NetworkListSnapshotApplyCompletionScheduling
{
    init() {}

    func schedule(_ completion: @escaping @MainActor @Sendable () -> Void) {
        completion()
    }
}
#endif

#if canImport(UIKit)
import Foundation

extension DOMTreeTextView {
    @MainActor
    final class ReloadScheduler {
        private var pendingInvalidation: DOMTreeTextView.Invalidation?
        private var scheduledTask: Task<Void, Never>?

        var hasScheduledReload: Bool {
            scheduledTask != nil
        }

        isolated deinit {
            scheduledTask?.cancel()
        }

        func cancel() {
            pendingInvalidation = nil
            scheduledTask?.cancel()
            scheduledTask = nil
        }

        func schedule(
            for invalidation: DOMTreeTextView.Invalidation,
            reload: @escaping @MainActor (DOMTreeTextView.Invalidation?) -> Void
        ) {
            if invalidation.requiresImmediateReload {
                cancel()
                reload(invalidation)
                return
            }

            pendingInvalidation = pendingInvalidation?.merged(with: invalidation) ?? invalidation
            guard scheduledTask == nil else {
                return
            }
            scheduledTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let invalidation = pendingInvalidation
                pendingInvalidation = nil
                scheduledTask = nil
                reload(invalidation)
            }
        }
    }
}
#endif

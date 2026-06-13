#if canImport(UIKit)
import Foundation

@MainActor
final class MainActorDelayScheduler {
    private var task: Task<Void, Never>?

    var hasScheduledDelay: Bool {
        task != nil
    }

    isolated deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(after duration: Duration, operation: @escaping @Sendable @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self, Task.isCancelled == false else {
                return
            }
            task = nil
            operation()
        }
    }
}
#endif

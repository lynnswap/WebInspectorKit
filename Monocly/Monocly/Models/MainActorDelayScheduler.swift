import Foundation

@MainActor
protocol MainActorDelayScheduling: AnyObject {
    var hasScheduledDelay: Bool { get }

    func cancel()
    func schedule(after duration: Duration, operation: @escaping @Sendable @MainActor () -> Void)
    func schedule(nanoseconds: UInt64, operation: @escaping @Sendable @MainActor () -> Void)
}

@MainActor
final class MainActorDelayScheduler: MainActorDelayScheduling {
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

    func schedule(nanoseconds: UInt64, operation: @escaping @Sendable @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
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

import Foundation

@MainActor
final class UIUpdateCoalescer {
    private var isScheduled = false
    private var scheduledTask: Task<Void, Never>?

    func schedule(_ update: @escaping @MainActor () -> Void) {
        guard !isScheduled else {
            return
        }
        isScheduled = true
        scheduledTask = Task { [weak self] in
            guard let self else {
                return
            }
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            isScheduled = false
            scheduledTask = nil
            update()
        }
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
        isScheduled = false
    }
}

import Foundation

@MainActor
final class UIUpdateCoalescer {
    private var isScheduled = false

    func schedule(_ update: @escaping @MainActor () -> Void) {
        guard !isScheduled else {
            return
        }
        isScheduled = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await Task.yield()
            isScheduled = false
            update()
        }
    }
}

import Foundation

/// Applies the elements of an async sequence on the main actor until it is
/// stopped or the sequence ends.
struct WebInspectorEventPump: Sendable {
    private let task: Task<Void, Never>

    init<Event: Sendable, Events: AsyncSequence & Sendable>(
        stream: Events,
        apply: @escaping @MainActor (Event) async -> Void,
        onFailure: @escaping @MainActor (any Error) async -> Void
    ) where Events.Element == Event {
        task = Task.detached(priority: .userInitiated) {
            do {
                for try await event in stream {
                    if Task.isCancelled {
                        return
                    }
                    await apply(event)
                }
            } catch {
                guard Task.isCancelled == false else {
                    return
                }
                await onFailure(error)
            }
        }
    }

    func stop() {
        task.cancel()
    }
}

import Foundation

struct WebInspectorEventPump: Sendable {
    private let task: Task<Void, Never>

    init<Event: Sendable, Events: AsyncSequence & Sendable>(
        stream: Events,
        isolation: isolated (any Actor),
        apply: @escaping (Event) async -> Void,
        onFailure: @escaping (any Error) async -> Void
    ) where Events.Element == Event {
        let target = WebInspectorEventPumpTarget(
            apply: apply,
            onFailure: onFailure
        )
        task = Task.detached(priority: .userInitiated) {
            do {
                for try await event in stream {
                    if Task.isCancelled {
                        return
                    }
                    await target.apply(event, isolation: isolation)
                }
            } catch {
                guard Task.isCancelled == false else {
                    return
                }
                await target.handleFailure(error, isolation: isolation)
            }
        }
    }

    func stop() {
        task.cancel()
    }
}

// The detached task may carry this target across executors, but it never invokes
// the non-Sendable apply closure directly; apply(_:isolation:) runs on the
// WebInspectorContext owner actor passed to the pump initializer.
private final class WebInspectorEventPumpTarget<Event: Sendable>: @unchecked Sendable {
    private let applyEvent: (Event) async -> Void
    private let failureHandler: (any Error) async -> Void

    init(
        apply: @escaping (Event) async -> Void,
        onFailure: @escaping (any Error) async -> Void
    ) {
        applyEvent = apply
        failureHandler = onFailure
    }

    func apply(_ event: Event, isolation: isolated (any Actor)) async {
        _ = isolation
        await applyEvent(event)
    }

    func handleFailure(_ error: any Error, isolation: isolated (any Actor)) async {
        _ = isolation
        await failureHandler(error)
    }
}

import Foundation

struct WebInspectorEventPump: Sendable {
    private let task: Task<Void, Never>

    init<Event: Sendable, Events: AsyncSequence & Sendable>(
        stream: Events,
        isolation: isolated (any Actor),
        apply: @escaping (Event) -> Void
    ) where Events.Element == Event, Events.Failure == Never {
        let target = WebInspectorEventPumpTarget(apply: apply)
        task = Task.detached(priority: .userInitiated) {
            for await event in stream {
                if Task.isCancelled {
                    break
                }
                await target.apply(event, isolation: isolation)
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
    private let applyEvent: (Event) -> Void

    init(apply: @escaping (Event) -> Void) {
        applyEvent = apply
    }

    func apply(_ event: Event, isolation: isolated (any Actor)) {
        _ = isolation
        applyEvent(event)
    }
}

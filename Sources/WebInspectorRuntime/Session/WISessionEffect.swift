import Foundation
import WebInspectorModel

@MainActor
final class WISessionEffectRunner {
    private var task: Task<Void, Never>?

    func run(_ effects: [WISessionEffect], in session: WISession) {
        guard effects.isEmpty == false else {
            return
        }

        task = Task { [task] in
            await task?.value
            for effect in effects {
                guard !Task.isCancelled else {
                    return
                }
                await run(effect, in: session)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(_ effect: WISessionEffect, in session: WISession) async {
        switch effect {
        case let .dom(command):
            await session.dom.execute(command)

        case let .network(command):
            await session.network.execute(command)
        }
    }
}

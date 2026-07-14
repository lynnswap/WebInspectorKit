import Foundation
import Synchronization

private final class _WebInspectorWeakContextIngress: @unchecked Sendable {
    weak var value: WebInspectorModelContextIngress?

    init(_ value: WebInspectorModelContextIngress) {
        self.value = value
    }
}

/// Linearizes context issuance against terminal container close.
package final class WebInspectorModelContextRegistry: @unchecked Sendable {
    private enum Phase {
        case open
        case closing
        case closed
    }

    private struct State {
        var phase = Phase.open
        var ingresses: [UUID: _WebInspectorWeakContextIngress] = [:]
    }

    private let state = Mutex(State())
    private let store: WebInspectorModelStore
    private let closeReply = WebInspectorContextReply<Void>()

    package init(store: WebInspectorModelStore) {
        self.store = store
    }

    package func issue(
        for container: WebInspectorModelContainer,
        executor: WebInspectorModelContextExecutor
    ) throws -> WebInspectorModelContext {
        let context: WebInspectorModelContext = try state.withLock { state in
            guard case .open = state.phase else {
                throw WebInspectorModelContextError.containerClosed
            }
            let context = WebInspectorModelContext(
                container: container,
                executor: executor,
                store: store
            ) { [weak self] registrationID in
                self?.didClose(registrationID)
            }
            state.ingresses[context.lifecycle.ingress.registrationID] =
                _WebInspectorWeakContextIngress(context.lifecycle.ingress)
            return context
        }
        store.registerSynchronously(context.lifecycle.ingress)
        return context
    }

    package func makeClosedContext(
        for container: WebInspectorModelContainer,
        executor: WebInspectorModelContextExecutor
    ) -> WebInspectorModelContext {
        let context = WebInspectorModelContext(
            container: container,
            executor: executor,
            store: store,
            didClose: { _ in }
        )
        _ = context.lifecycle.beginClose(reason: .containerClosed)
        return context
    }

    package func closeAll() async {
        let admission = state.withLock {
            state -> (
                startsClose: Bool,
                ingresses: [WebInspectorModelContextIngress]
            ) in
            switch state.phase {
            case .open:
                state.phase = .closing
            case .closing, .closed:
                return (false, [])
            }
            return (true, state.ingresses.values.compactMap(\.value))
        }

        guard admission.startsClose else {
            _ = try? await closeReply.value()
            return
        }

        let replies = admission.ingresses.compactMap {
            $0.beginClose(reason: .containerClosed)
        }
        for reply in replies {
            _ = try? await reply.value()
        }

        state.withLock { state in
            state.phase = .closed
            state.ingresses.removeAll(keepingCapacity: false)
        }
        closeReply.succeed(())
    }

    package var isOpen: Bool {
        state.withLock { state in
            if case .open = state.phase { true } else { false }
        }
    }

    private func didClose(_ registrationID: UUID) {
        let removed = state.withLock { state in
            state.ingresses.removeValue(forKey: registrationID) != nil
        }
        if removed {
            store.unregisterSynchronously(registrationID)
        }
    }
}

import WebInspectorTransport

@MainActor
package protocol ProtocolDomainEventDispatcher {
    var domain: ProtocolDomain { get }

    func dispatch(_ event: ProtocolEventEnvelope) async throws
}

@MainActor
package final class ProtocolDomainEventDispatcherRegistry {
    private var dispatchersByDomain: [ProtocolDomain: any ProtocolDomainEventDispatcher]

    package init(_ dispatchers: [any ProtocolDomainEventDispatcher] = []) {
        dispatchersByDomain = [:]
        for dispatcher in dispatchers {
            register(dispatcher)
        }
    }

    package func register(_ dispatcher: any ProtocolDomainEventDispatcher) {
        dispatchersByDomain[dispatcher.domain] = dispatcher
    }

    @discardableResult
    package func dispatch(_ event: ProtocolEventEnvelope) async throws -> Bool {
        guard let dispatcher = dispatchersByDomain[event.domain] else {
            return false
        }
        try await dispatcher.dispatch(event)
        return true
    }
}

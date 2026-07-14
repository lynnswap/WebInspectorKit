import Foundation

package struct DomainEndpoint: Sendable {
    package let proxyReference: WebInspectorProxyReference
    package let route: WebInspectorRoute

    package func dispatch<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>
    ) async throws -> Result {
        guard let proxy = proxyReference.resolve() else { throw WebInspectorProxyError.closed }
        return try await proxy.send(command, route: route)
    }

    package func openScope<Element: Sendable>(
        descriptor: WebInspectorOrderedScopeDescriptor<Element>,
        buffering: WebInspectorEventBufferingPolicy
    ) async throws -> WebInspectorOrderedEventScope<Element> {
        guard let proxy = proxyReference.resolve() else { throw WebInspectorProxyError.closed }
        return try await proxy.openScope(descriptor: descriptor, buffering: buffering)
    }
}

package protocol WebInspectorDomainHandle: Sendable {
    var endpoint: DomainEndpoint { get }
}

package protocol WebInspectorEventDomainHandle: WebInspectorDomainHandle {
    associatedtype Event: Sendable
    static var eventDecoder: WebInspectorEventDecoder<Event> { get }
    static var eventCapability: WebInspectorDomainCapabilityDescriptor { get }
}

package extension WebInspectorEventDomainHandle {
    func _withEvents<Output>(
        buffering: WebInspectorEventBufferingPolicy,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Event>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        _ = isolation
        let scope = try await endpoint.openScope(
            descriptor: WebInspectorOrderedScopeDescriptor(
                decoders: [Self.eventDecoder],
                capabilities: [Self.eventCapability]
            ),
            buffering: buffering
        )

        let operationResult: Result<Output, any Error>
        do { operationResult = .success(try await operation(scope.events)) }
        catch { operationResult = .failure(error) }
        await scope.close()

        switch operationResult {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }
}

import Foundation

public struct WITransportCommandChannel: Sendable {
    private let scope: WITransportTargetScope
    private let sender: @Sendable (_ scope: WITransportTargetScope, _ method: String, _ parametersPayload: WITransportPayload?) async throws -> WITransportPayload
    private let subscriber: @Sendable (_ scope: WITransportTargetScope, _ methods: Set<String>?, _ bufferingLimit: Int?) async -> AsyncStream<WITransportEventEnvelope>

    init(
        scope: WITransportTargetScope,
        sender: @escaping @Sendable (_ scope: WITransportTargetScope, _ method: String, _ parametersPayload: WITransportPayload?) async throws -> WITransportPayload,
        subscriber: @escaping @Sendable (_ scope: WITransportTargetScope, _ methods: Set<String>?, _ bufferingLimit: Int?) async -> AsyncStream<WITransportEventEnvelope>
    ) {
        self.scope = scope
        self.sender = sender
        self.subscriber = subscriber
    }

    public func send<C: WITransportRootCommand>(_ command: C) async throws -> C.Response {
        try ensureScope(expected: .root)
        let payload = try await sender(scope, C.method, encodeParameters(command.parameters))
        return try decodeResponse(C.Response.self, from: payload)
    }

    public func send<C: WITransportPageCommand>(_ command: C) async throws -> C.Response {
        try ensureScope(expected: .page)
        let payload = try await sender(scope, C.method, encodeParameters(command.parameters))
        return try decodeResponse(C.Response.self, from: payload)
    }

    public func events(methods: Set<String>? = nil, bufferingLimit: Int? = nil) -> AsyncStream<WITransportEventEnvelope> {
        AsyncStream { continuation in
            let relayTask = Task {
                let stream = await subscriber(scope, methods, bufferingLimit)
                for await event in stream {
                    continuation.yield(event)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                relayTask.cancel()
            }
        }
    }
}

private extension WITransportCommandChannel {
    func ensureScope(expected: WITransportTargetScope) throws {
        guard scope == expected else {
            throw WITransportError.invalidChannelScope(expected: expected, actual: scope)
        }
    }

    func encodeParameters<Parameters: Encodable>(_ parameters: Parameters) throws -> WITransportPayload? {
        if Parameters.self == WIEmptyTransportParameters.self {
            return nil
        }

        if let fastParameters = parameters as? any WITransportObjectEncodable {
            let object = fastParameters.wiTransportObject()
            if transportIsEmptyJSONObject(object) {
                return nil
            }
            return .object(object)
        }

        do {
            let data = try JSONEncoder().encode(parameters)
            if data == Data("{}".utf8) {
                return nil
            }
            return .data(data)
        } catch {
            throw WITransportError.invalidCommandEncoding(error.localizedDescription)
        }
    }

    func decodeResponse<Response: Decodable>(_ type: Response.Type, from payload: WITransportPayload) throws -> Response {
        do {
            return try payload.decode(Response.self)
        } catch {
            throw WITransportError.invalidResponse(error.localizedDescription)
        }
    }
}

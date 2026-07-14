import Foundation

package struct WebInspectorProtocolDomainToken: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package var description: String { rawValue }
}

package struct WebInspectorProtocolMethod: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package init(domain: WebInspectorProtocolDomainToken, name: String) {
        rawValue = "\(domain.rawValue).\(name)"
    }

    package var domain: WebInspectorProtocolDomainToken {
        let prefix = rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
        return WebInspectorProtocolDomainToken(rawValue: prefix.map(String.init) ?? rawValue)
    }

    package var name: String {
        let components = rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return components.count == 2 ? String(components[1]) : rawValue
    }

    package var description: String { rawValue }
}

package struct WebInspectorEventSequence: RawRepresentable, Hashable, Comparable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct WebInspectorRoutedEventEnvelope: Sendable {
    package let sequence: WebInspectorEventSequence
    package let generation: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID?
    package let agentTargetID: WebInspectorTarget.ID?
    package let semanticTarget: WebInspectorTarget?
    package let agentTarget: WebInspectorTarget?
    package let method: WebInspectorProtocolMethod
    package let parameters: Data
    package let targetScopeRawValue: String?

    package init(
        sequence: WebInspectorEventSequence,
        generation: WebInspectorPage.Generation,
        semanticTargetID: WebInspectorTarget.ID?,
        agentTargetID: WebInspectorTarget.ID?,
        semanticTarget: WebInspectorTarget?,
        agentTarget: WebInspectorTarget?,
        method: WebInspectorProtocolMethod,
        parameters: Data,
        targetScopeRawValue: String?
    ) {
        self.sequence = sequence
        self.generation = generation
        self.semanticTargetID = semanticTargetID
        self.agentTargetID = agentTargetID
        self.semanticTarget = semanticTarget
        self.agentTarget = agentTarget
        self.method = method
        self.parameters = parameters
        self.targetScopeRawValue = targetScopeRawValue
    }
}

package struct WebInspectorRoutedEvent<Value: Sendable>: Sendable {
    package let sequence: WebInspectorEventSequence
    package let generation: WebInspectorPage.Generation
    package let semanticTargetID: WebInspectorTarget.ID?
    package let agentTargetID: WebInspectorTarget.ID?
    package let semanticTarget: WebInspectorTarget?
    package let agentTarget: WebInspectorTarget?
    package let method: WebInspectorProtocolMethod
    package let value: Value
}

package struct WebInspectorWireDecodeContext: Sendable {
    package let generation: WebInspectorPage.Generation
    package let targetID: WebInspectorTarget.ID?
    package let targetScopeRawValue: String?
}

package enum WebInspectorCommandTarget: Hashable, Sendable {
    case endpoint
    case currentPage
    case root
    case target(WebInspectorTarget.ID)
}

package struct WebInspectorWireCommand<Result: Sendable>: Sendable {
    package let method: WebInspectorProtocolMethod
    package let parameters: Data
    package let target: WebInspectorCommandTarget
    package let decodeReply: @Sendable (Data, WebInspectorWireDecodeContext) throws -> Result

    package init(
        method: WebInspectorProtocolMethod,
        parameters: Data = Data("{}".utf8),
        target: WebInspectorCommandTarget = .endpoint,
        decodeReply: @escaping @Sendable (Data, WebInspectorWireDecodeContext) throws -> Result
    ) {
        self.method = method
        self.parameters = parameters
        self.target = target
        self.decodeReply = decodeReply
    }

    package static func void(
        _ method: WebInspectorProtocolMethod,
        parameters: Data = Data("{}".utf8),
        target: WebInspectorCommandTarget = .endpoint
    ) -> WebInspectorWireCommand<Void> where Result == Void {
        WebInspectorWireCommand<Void>(
            method: method,
            parameters: parameters,
            target: target,
            decodeReply: { _, _ in () }
        )
    }
}

package struct WebInspectorEventDecoder<Event: Sendable>: Sendable {
    package let domain: WebInspectorProtocolDomainToken
    private let decodeBody: @Sendable (WebInspectorRoutedEventEnvelope) throws -> Event

    package init(
        domain: WebInspectorProtocolDomainToken,
        decode: @escaping @Sendable (WebInspectorRoutedEventEnvelope) throws -> Event
    ) {
        self.domain = domain
        decodeBody = decode
    }

    package func decode(_ envelope: WebInspectorRoutedEventEnvelope) throws -> Event {
        try decodeBody(envelope)
    }

    package func map<Mapped: Sendable>(
        _ transform: @escaping @Sendable (Event) -> Mapped
    ) -> WebInspectorEventDecoder<Mapped> {
        WebInspectorEventDecoder<Mapped>(domain: domain) { envelope in
            transform(try decodeBody(envelope))
        }
    }

    package func routed() -> WebInspectorEventDecoder<WebInspectorRoutedEvent<Event>> {
        WebInspectorEventDecoder<WebInspectorRoutedEvent<Event>>(domain: domain) { envelope in
            WebInspectorRoutedEvent(
                sequence: envelope.sequence,
                generation: envelope.generation,
                semanticTargetID: envelope.semanticTargetID,
                agentTargetID: envelope.agentTargetID,
                semanticTarget: envelope.semanticTarget,
                agentTarget: envelope.agentTarget,
                method: envelope.method,
                value: try decodeBody(envelope)
            )
        }
    }
}

package struct WebInspectorEventDecodingError: Error, Sendable, Equatable {
    package let domain: WebInspectorProtocolDomainToken
    package let method: WebInspectorProtocolMethod
    package let sequence: WebInspectorEventSequence
    package let message: String

    package init(envelope: WebInspectorRoutedEventEnvelope, error: any Error) {
        domain = envelope.method.domain
        method = envelope.method
        sequence = envelope.sequence
        message = String(describing: error)
    }
}

package enum WebInspectorWireJSON {
    package static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    package static func object(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    package static func objectData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    package static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

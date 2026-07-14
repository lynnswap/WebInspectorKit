import Foundation

/// A protocol event that has not been decoded into a typed event case.
public struct RawEvent: Sendable {
    /// The full protocol method, such as `Network.requestWillBeSent`.
    public let method: String

    /// Semantic JSON parameters. Explicit nulls and fragments are preserved.
    public let params: Data

    /// The domain derived from ``method``.
    public var domain: String {
        method.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? method
    }

    /// The short event name derived from ``method``.
    public var name: String {
        let components = method.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        return components.count == 2 ? String(components[1]) : method
    }

    public init(method: String, params: Data = Data("{}".utf8)) {
        self.method = method
        self.params = params
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: params)
    }
}

package extension RawEvent {
    init(_ envelope: WebInspectorRoutedEventEnvelope) {
        self.init(method: envelope.method.rawValue, params: envelope.parameters)
    }
}

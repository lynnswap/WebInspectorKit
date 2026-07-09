import Foundation

/// A protocol event that has not been decoded into a typed event case.
public struct RawEvent: Sendable {
    /// The protocol domain that emitted the event.
    public let domain: String

    /// The protocol event method name.
    public let method: String

    /// Raw JSON parameters for the event.
    public let params: Data

    /// Creates a raw protocol event.
    public init(domain: String, method: String, params: Data = Data()) {
        self.domain = domain
        self.method = method
        self.params = params
    }

    /// Decodes ``params`` as the supplied `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: params)
    }
}

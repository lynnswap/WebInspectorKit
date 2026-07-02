import Foundation

public struct RawEvent: Sendable {
    public let domain: String
    public let method: String
    public let params: Data

    public init(domain: String, method: String, params: Data = Data()) {
        self.domain = domain
        self.method = method
        self.params = params
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: params)
    }
}

import Foundation

extension KeyedDecodingContainer {
    func decodeStringOrInteger(forKey key: Key) throws -> String {
        if let string = try? decode(String.self, forKey: key) {
            return string
        }
        if let integer = try? decode(Int.self, forKey: key) {
            return String(integer)
        }
        if let double = try? decode(Double.self, forKey: key),
           double.rounded(.towardZero) == double {
            return String(Int(double))
        }
        throw DecodingError.typeMismatch(
            String.self,
            .init(
                codingPath: codingPath + [key],
                debugDescription: "Expected string or integer identifier."
            )
        )
    }
}

func liveProxyDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
}

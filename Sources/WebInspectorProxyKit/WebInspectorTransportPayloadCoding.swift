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

    func decodeStringOrIntegerIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try decodeNil(forKey: key) == false else {
            return nil
        }
        return try decodeStringOrInteger(forKey: key)
    }
}

func webInspectorTransportDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
}

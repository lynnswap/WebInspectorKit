import Foundation

/// A validated Web Inspector protocol JSON object.
///
/// The value always contains a top-level JSON object. Its stored bytes use a
/// canonical sorted-key representation, so equality compares JSON object
/// semantics rather than the caller's whitespace or key ordering.
public struct WebInspectorTestJSONObject: Equatable, Sendable {
    /// The empty JSON object.
    public static let empty = WebInspectorTestJSONObject(
        canonicalData: Data("{}".utf8)
    )

    private let canonicalData: Data

    /// Validates and canonicalizes a JSON object string.
    ///
    /// - Throws: ``WebInspectorTestPeerError/invalidJSONObject`` when `json`
    ///   is not valid JSON or its top-level value is not an object.
    public init(json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw WebInspectorTestPeerError.invalidJSONObject
        }
        try self.init(data: data)
    }

    /// Validates and canonicalizes UTF-8 JSON object data.
    ///
    /// - Throws: ``WebInspectorTestPeerError/invalidJSONObject`` when `data`
    ///   is not valid JSON or its top-level value is not an object.
    public init(data: Data) throws {
        try self.init(validating: data)
    }

    /// Encodes a typed fixture and validates that it produces a JSON object.
    ///
    /// - Throws: ``WebInspectorTestPeerError/invalidJSONObject`` when encoding
    ///   fails or `value` does not encode as a top-level object.
    public init<Value: Encodable>(encoding value: Value) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw WebInspectorTestPeerError.invalidJSONObject
        }
        try self.init(data: data)
    }

    /// The canonical sorted-key UTF-8 representation of the object.
    public var data: Data {
        canonicalData
    }

    /// Decodes the object into a test fixture type.
    public func decode<Value: Decodable>(
        _ type: Value.Type
    ) throws -> Value {
        try JSONDecoder().decode(type, from: canonicalData)
    }

    init(validating data: Data) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WebInspectorTestPeerError.invalidJSONObject
        }
        guard let object = value as? [String: Any] else {
            throw WebInspectorTestPeerError.invalidJSONObject
        }
        try self.init(validatedObject: object)
    }

    init(validatedObject object: [String: Any]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw WebInspectorTestPeerError.invalidJSONObject
        }
        self.init(canonicalData: data)
    }

    var utf8String: String {
        guard let string = String(data: canonicalData, encoding: .utf8) else {
            preconditionFailure("Canonical JSON object bytes must remain UTF-8.")
        }
        return string
    }

    private init(canonicalData: Data) {
        self.canonicalData = canonicalData
    }
}

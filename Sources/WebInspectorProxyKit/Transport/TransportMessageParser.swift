import Foundation

package struct ParsedProtocolMessage: Equatable, Sendable {
    package var id: UInt64?
    package var method: String?
    package var paramsData: Data
    package var resultData: Data
    package var errorMessage: String?

    package init(
        id: UInt64?,
        method: String?,
        paramsData: Data,
        resultData: Data,
        errorMessage: String?
    ) {
        self.id = id
        self.method = method
        self.paramsData = paramsData
        self.resultData = resultData
        self.errorMessage = errorMessage
    }
}

package struct TransportMessageParsePolicy: Equatable, Sendable {
    package static let `default` = TransportMessageParsePolicy(detachedParsingThresholdBytes: 64 * 1024)

    package var detachedParsingThresholdBytes: Int

    package init(detachedParsingThresholdBytes: Int) {
        self.detachedParsingThresholdBytes = max(0, detachedParsingThresholdBytes)
    }

    package func shouldParseDetached(_ message: String) -> Bool {
        message.utf8.count >= detachedParsingThresholdBytes
    }

    package func shouldParseDetached(_ data: Data) -> Bool {
        data.count >= detachedParsingThresholdBytes
    }
}

package enum TransportMessageParser {
    private enum ParseError: Error {
        case invalidJSON
        case invalidEnvelope
        case invalidField(String)
    }

    // Decoder descriptions can include inspected-page values. Report only the
    // failure category and schema field at the transport boundary.
    package static func failureDescription(_ error: any Error) -> String {
        switch error {
        case ParseError.invalidJSON:
            return "Invalid JSON."
        case ParseError.invalidEnvelope:
            return "Expected a protocol message object with an id or method."
        case let ParseError.invalidField(field):
            return "Invalid protocol field: \(field)."
        case let DecodingError.keyNotFound(key, _):
            return "Missing required field: \(key.stringValue)."
        case DecodingError.typeMismatch:
            return "A protocol field has an unexpected type."
        case DecodingError.valueNotFound:
            return "A required protocol value is null."
        case DecodingError.dataCorrupted:
            return "Invalid encoded protocol data."
        default:
            return "Protocol message decoding failed."
        }
    }

    package static func parse(
        _ message: String,
        policy: TransportMessageParsePolicy = .default
    ) async throws -> ParsedProtocolMessage {
        guard policy.shouldParseDetached(message) else {
            return try parseSync(message)
        }
        return try await Task.detached(priority: .userInitiated) {
            try parseSync(message)
        }.value
    }

    package static func makeCommandString(id: UInt64, method: String, parametersData: Data) throws -> String {
        var object: [String: Any] = [
            "id": id,
            "method": method,
        ]
        object["params"] = try jsonObject(from: parametersData)
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw TransportSession.Error.malformedMessage
        }
        return string
    }

    package static func makeTargetWrapperCommandString(
        id: UInt64,
        targetIdentifier: String,
        message: String
    ) throws -> String {
        let object: [String: Any] = [
            "id": id,
            "method": "Target.sendMessageToTarget",
            "params": [
                "targetId": targetIdentifier,
                "message": message,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw TransportSession.Error.malformedMessage
        }
        return string
    }

    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    package static func decodeAsync<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data,
        policy: TransportMessageParsePolicy = .default
    ) async throws -> T {
        guard policy.shouldParseDetached(data) else {
            return try decode(type, from: data)
        }
        return try await Task.detached(priority: .userInitiated) {
            try decode(type, from: data)
        }.value
    }

    package static func jsonObject(from data: Data) throws -> Any {
        guard data.isEmpty == false else {
            return [:]
        }
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    private static func jsonData(_ object: Any?, field: String) throws -> Data {
        guard let object else {
            return Data("{}".utf8)
        }
        guard object is [String: Any] else {
            throw ParseError.invalidField(field)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func parseSync(_ message: String) throws -> ParsedProtocolMessage {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: Data(message.utf8), options: .fragmentsAllowed)
        } catch {
            throw ParseError.invalidJSON
        }
        guard let object = decoded as? [String: Any] else {
            throw ParseError.invalidEnvelope
        }
        let id = try identifierValue(object["id"])
        let method = try stringValue(object["method"], field: "method")
        guard id != nil || method != nil else {
            throw ParseError.invalidEnvelope
        }
        let errorMessage: String?
        if let error = object["error"] {
            guard let error = error as? [String: Any],
                  let message = try stringValue(error["message"], field: "error.message") else {
                throw ParseError.invalidField("error")
            }
            errorMessage = message
        } else {
            errorMessage = nil
        }

        return ParsedProtocolMessage(
            id: id,
            method: method,
            paramsData: try jsonData(object["params"], field: "params"),
            resultData: try jsonData(object["result"], field: "result"),
            errorMessage: errorMessage
        )
    }

    private static func identifierValue(_ value: Any?) throws -> UInt64? {
        guard let value else { return nil }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           let id = UInt64(number.stringValue) {
            return id
        }
        if let string = value as? String, let id = UInt64(string) {
            return id
        }
        throw ParseError.invalidField("id")
    }

    private static func stringValue(_ value: Any?, field: String) throws -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        throw ParseError.invalidField(field)
    }
}

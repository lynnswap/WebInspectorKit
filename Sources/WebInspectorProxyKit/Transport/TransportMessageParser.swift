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

    package static func jsonData(_ object: Any?) -> Data {
        guard let object else {
            return Data("{}".utf8)
        }
        if object is NSNull {
            return Data("{}".utf8)
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return Data("{}".utf8)
        }
        return data
    }

    private static func parseSync(_ message: String) throws -> ParsedProtocolMessage {
        guard let data = message.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw TransportSession.Error.malformedMessage
        }

        return ParsedProtocolMessage(
            id: identifierValue(object["id"]),
            method: stringValue(object["method"]),
            paramsData: jsonData(object["params"]),
            resultData: jsonData(object["result"]),
            errorMessage: stringValue((object["error"] as? [String: Any])?["message"])
        )
    }

    private static func identifierValue(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

import Foundation

package struct ParsedProtocolMessage: Sendable {
    package let id: UInt64?
    package let method: WebInspectorProtocolMethod?
    package let parameters: Data
    package let result: Data
    package let errorMessage: String?
}

package struct ConnectionMessageParsePolicy: Equatable, Sendable {
    package static let `default` = ConnectionMessageParsePolicy(
        detachedParsingThresholdBytes: 64 * 1024
    )

    package let detachedParsingThresholdBytes: Int

    package init(detachedParsingThresholdBytes: Int) {
        self.detachedParsingThresholdBytes = max(0, detachedParsingThresholdBytes)
    }
}

package enum ConnectionMessageParser {
    package static func parse(
        _ message: String,
        policy: ConnectionMessageParsePolicy = .default
    ) async throws -> ParsedProtocolMessage {
        if message.utf8.count < policy.detachedParsingThresholdBytes {
            return try parseSynchronously(message)
        }
        return try await Task.detached(priority: .userInitiated) {
            try parseSynchronously(message)
        }.value
    }

    package static func makeCommandString(
        id: UInt64,
        method: WebInspectorProtocolMethod,
        parameters: Data
    ) throws -> String {
        let object: [String: Any] = [
            "id": id,
            "method": method.rawValue,
            "params": try WebInspectorWireJSON.object(from: parameters),
        ]
        return try string(from: object)
    }

    package static func makeTargetWrapperCommandString(
        id: UInt64,
        targetID: ProtocolTarget.ID,
        message: String
    ) throws -> String {
        try string(from: [
            "id": id,
            "method": "Target.sendMessageToTarget",
            "params": [
                "targetId": targetID.rawValue,
                "message": message,
            ],
        ])
    }

    private static func parseSynchronously(_ message: String) throws -> ParsedProtocolMessage {
        guard let data = message.data(using: .utf8) else {
            throw ConnectionError.unreadableEnvelope
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ConnectionError.unreadableEnvelope
        }
        guard let object = value as? [String: Any] else {
            throw ConnectionError.unreadableEnvelope
        }

        return ParsedProtocolMessage(
            id: identifier(object["id"]),
            method: method(object["method"]),
            parameters: try memberData(named: "params", in: object, absent: [:]),
            result: try memberData(named: "result", in: object, absent: [:]),
            errorMessage: errorMessage(object["error"])
        )
    }

    private static func memberData(
        named name: String,
        in object: [String: Any],
        absent: Any
    ) throws -> Data {
        let value = object.keys.contains(name) ? object[name]! : absent
        do {
            return try WebInspectorWireJSON.data(value)
        } catch {
            throw ConnectionError.unreadableEnvelope
        }
    }

    private static func identifier(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        if let value = value as? NSNumber { return value.uint64Value }
        if let value = value as? String { return UInt64(value) }
        return nil
    }

    private static func method(_ value: Any?) -> WebInspectorProtocolMethod? {
        if let value = value as? String {
            return WebInspectorProtocolMethod(rawValue: value)
        }
        return nil
    }

    private static func errorMessage(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let message = object["message"] as? String { return message }
        if let message = object["message"] as? NSNumber { return message.stringValue }
        return nil
    }

    private static func string(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw ConnectionError.unreadableEnvelope
        }
        return string
    }
}

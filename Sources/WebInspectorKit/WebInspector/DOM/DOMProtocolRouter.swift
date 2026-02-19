import Foundation
import OSLog
import WebInspectorKitCore

@MainActor
final class DOMProtocolRouter {
    struct RoutingOutcome {
        let responseJSON: String?
        let responseObject: [String: Any]?
        let recoverableError: String?
    }

    private let session: DOMSession
    private let logger = Logger(subsystem: "WebInspectorKit", category: "DOMProtocolRouter")

    init(session: DOMSession) {
        self.session = session
    }

    func route(payload: Any?, configuration: DOMConfiguration) async -> RoutingOutcome {
        guard let request = decodeRequest(from: payload) else {
            let message = "DOM protocol payload decode failed"
            let requestID = decodeRequestIdentifier(from: payload) ?? 0
            return RoutingOutcome(
                responseJSON: encodeResponse(
                    .init(id: requestID, result: nil, error: .init(message: message))
                ),
                responseObject: makeObjectResponse(id: requestID, result: nil, errorMessage: message),
                recoverableError: message
            )
        }

        do {
            switch request.method {
            case "DOM.getDocument":
                let depth = request.params.intValue(forKey: "depth") ?? configuration.snapshotDepth
                let snapshot = try await session.captureSnapshotPayload(maxDepth: depth)
                let object = makeObjectResponse(id: request.id, result: snapshot, errorMessage: nil)
                return RoutingOutcome(
                    responseJSON: nil,
                    responseObject: object,
                    recoverableError: nil
                )

            case "DOM.requestChildNodes":
                let depth = request.params.intValue(forKey: "depth") ?? configuration.subtreeDepth
                let nodeID = request.params.intValue(forKey: "nodeId") ?? 0
                let subtree = try await session.captureSubtreePayload(nodeId: nodeID, maxDepth: depth)
                let object = makeObjectResponse(id: request.id, result: subtree, errorMessage: nil)
                return RoutingOutcome(
                    responseJSON: nil,
                    responseObject: object,
                    recoverableError: nil
                )

            case "DOM.highlightNode":
                if let nodeID = request.params.intValue(forKey: "nodeId") {
                    await session.highlight(nodeId: nodeID)
                }
                let object = makeObjectResponse(id: request.id, result: [:], errorMessage: nil)
                return RoutingOutcome(responseJSON: nil, responseObject: object, recoverableError: nil)

            case "Overlay.hideHighlight", "DOM.hideHighlight":
                await session.hideHighlight()
                let object = makeObjectResponse(id: request.id, result: [:], errorMessage: nil)
                return RoutingOutcome(responseJSON: nil, responseObject: object, recoverableError: nil)

            case "DOM.getSelectorPath":
                let nodeID = request.params.intValue(forKey: "nodeId") ?? 0
                let selectorPath = try await session.selectorPath(nodeId: nodeID)
                let object = makeObjectResponse(
                    id: request.id,
                    result: ["selectorPath": selectorPath],
                    errorMessage: nil
                )
                return RoutingOutcome(responseJSON: nil, responseObject: object, recoverableError: nil)

            default:
                let message = "Unsupported method: \(request.method)"
                return RoutingOutcome(
                    responseJSON: encodeResponse(
                        .init(
                            id: request.id,
                            result: nil,
                            error: .init(message: message)
                        )
                    ),
                    responseObject: makeObjectResponse(id: request.id, result: nil, errorMessage: message),
                    recoverableError: "Unsupported DOM protocol method: \(request.method)"
                )
            }
        } catch {
            logger.debug("protocol method failed: \(error.localizedDescription, privacy: .public)")
            return RoutingOutcome(
                responseJSON: encodeResponse(
                    .init(id: request.id, result: nil, error: .init(message: error.localizedDescription))
                ),
                responseObject: makeObjectResponse(id: request.id, result: nil, errorMessage: error.localizedDescription),
                recoverableError: error.localizedDescription
            )
        }
    }
}

private extension DOMProtocolRouter {
    struct ProtocolRequest: Decodable {
        let id: Int
        let method: String
        let params: JSONValue

        private enum CodingKeys: String, CodingKey {
            case id
            case method
            case params
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(ProtocolIdentifier.self, forKey: .id).value
            method = try container.decode(String.self, forKey: .method)
            params = try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:])
        }
    }

    struct ProtocolIdentifier: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
                return
            }
            if let stringValue = try? container.decode(String.self), let intValue = Int(stringValue) {
                value = intValue
                return
            }
            if let doubleValue = try? container.decode(Double.self) {
                guard doubleValue.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Protocol id must be finite"
                    )
                }
                guard doubleValue >= Double(Int.min), doubleValue <= Double(Int.max) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Protocol id is out of Int range"
                    )
                }
                let truncated = doubleValue.rounded(.towardZero)
                guard truncated == doubleValue else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Protocol id must be an integral number"
                    )
                }
                value = Int(truncated)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported protocol id type"
            )
        }
    }

    struct ProtocolResponse: Encodable {
        let id: Int
        let result: JSONValue?
        let error: ProtocolResponseError?
    }

    struct ProtocolResponseError: Encodable {
        let message: String
    }

    enum JSONValue: Codable, Sendable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                throw DecodingError.typeMismatch(
                    JSONValue.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .object(value):
                try container.encode(value)
            case let .array(value):
                try container.encode(value)
            case let .string(value):
                try container.encode(value)
            case let .number(value):
                try container.encode(value)
            case let .bool(value):
                try container.encode(value)
            case .null:
                try container.encodeNil()
            }
        }
    }

    func decodeRequest(from payload: Any?) -> ProtocolRequest? {
        guard let payload else {
            return nil
        }
        guard let data = payloadData(from: payload) else {
            return nil
        }
        return try? JSONDecoder().decode(ProtocolRequest.self, from: data)
    }

    func decodeRequestIdentifier(from payload: Any?) -> Int? {
        guard let payload else {
            return nil
        }
        if let dictionary = payload as? [String: Any] {
            return parseIdentifierValue(dictionary["id"])
        }
        if let dictionary = payload as? NSDictionary {
            return parseIdentifierValue(dictionary["id"])
        }
        if let data = payloadData(from: payload),
           let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dictionary = object as? [String: Any] {
            return parseIdentifierValue(dictionary["id"])
        }
        return nil
    }

    func parseIdentifierValue(_ value: Any?) -> Int? {
        if value is Bool {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return nil
            }
            return parseIntegralInt(from: value.doubleValue)
        }
        if let value = value as? String {
            return Int(value)
        }
        if let value = value as? Double {
            return parseIntegralInt(from: value)
        }
        return nil
    }

    func parseIntegralInt(from value: Double) -> Int? {
        guard value.isFinite else {
            return nil
        }
        let truncated = value.rounded(.towardZero)
        guard truncated == value else {
            return nil
        }
        guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
            return nil
        }
        return Int(truncated)
    }

    func payloadData(from payload: Any) -> Data? {
        if let data = payload as? Data {
            return data
        }
        if let string = payload as? String {
            return string.data(using: .utf8)
        }
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    func encodeResponse(_ response: ProtocolResponse) -> String? {
        guard let data = try? JSONEncoder().encode(response) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func makeObjectResponse(id: Int, result: Any?, errorMessage: String?) -> [String: Any] {
        var object: [String: Any] = ["id": id]
        if let errorMessage {
            object["error"] = ["message": errorMessage]
        } else {
            object["result"] = result ?? [:]
        }
        return object
    }
}

private extension DOMProtocolRouter.JSONValue {
    func intValue(forKey key: String) -> Int? {
        guard case let .object(object) = self, let value = object[key] else {
            return nil
        }
        switch value {
        case let .number(number):
            guard number.isFinite else {
                return nil
            }
            guard number >= Double(Int.min), number <= Double(Int.max) else {
                return nil
            }
            let truncated = number.rounded(.towardZero)
            guard truncated == number else {
                return nil
            }
            return Int(truncated)
        case let .string(string):
            return Int(string)
        default:
            return nil
        }
    }
}

import Foundation
import WebInspectorEngine

package enum ConsoleWire {}

package extension ConsoleWire {
    enum Transport {}
}

package extension ConsoleWire.Transport {
    enum JSONValue: Decodable, Sendable {
        case string(String)
        case number(Double)
        case boolean(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        package init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let boolValue = try? container.decode(Bool.self) {
                self = .boolean(boolValue)
            } else if let intValue = try? container.decode(Int.self) {
                self = .number(Double(intValue))
            } else if let doubleValue = try? container.decode(Double.self) {
                self = .number(doubleValue)
            } else if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
            } else if let objectValue = try? container.decode([String: JSONValue].self) {
                self = .object(objectValue)
            } else if let arrayValue = try? container.decode([JSONValue].self) {
                self = .array(arrayValue)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported Runtime.JSONValue payload."
                )
            }
        }

        package var summary: String {
            switch self {
            case .string(let stringValue):
                return stringValue
            case .number(let numericValue):
                if numericValue.rounded() == numericValue {
                    return String(Int(numericValue))
                }
                return String(numericValue)
            case .boolean(let boolValue):
                return boolValue ? "true" : "false"
            case .object(let objectValue):
                guard objectValue.isEmpty == false else {
                    return "{}"
                }
                let rendered = objectValue
                    .sorted(by: { $0.key < $1.key })
                    .prefix(3)
                    .map { key, value in "\(key): \(value.summary)" }
                    .joined(separator: ", ")
                return "{\(rendered)\(objectValue.count > 3 ? ", ..." : "")}"
            case .array(let arrayValue):
                let rendered = arrayValue
                    .prefix(3)
                    .map(\.summary)
                    .joined(separator: ", ")
                return "[\(rendered)\(arrayValue.count > 3 ? ", ..." : "")]"
            case .null:
                return "null"
            }
        }
    }

    struct RemoteObject: Decodable, Sendable {
        let type: String
        let subtype: String?
        let className: String?
        let value: JSONValue?
        let description: String?
        let objectId: String?
    }

    struct CallFrame: Decodable, Sendable {
        let functionName: String
        let url: String
        let lineNumber: Int
        let columnNumber: Int
    }

    final class StackTrace: Decodable, Sendable {
        let callFrames: [CallFrame]
        let parentStackTrace: StackTrace?

        init(callFrames: [CallFrame], parentStackTrace: StackTrace?) {
            self.callFrames = callFrames
            self.parentStackTrace = parentStackTrace
        }
    }

    struct ConsoleMessage: Decodable, Sendable {
        let source: WIConsoleMessageSource
        let level: WIConsoleMessageLevel
        let text: String
        let type: WIConsoleMessageType?
        let url: String?
        let line: Int?
        let column: Int?
        let repeatCount: Int?
        let parameters: [RemoteObject]?
        let stackTrace: StackTrace?
        let networkRequestId: String?
        let timestamp: Double?
    }

    struct MessageAddedEvent: Decodable, Sendable {
        let message: ConsoleMessage
    }

    struct MessageRepeatCountUpdatedEvent: Decodable, Sendable {
        let count: Int
        let timestamp: Double?
    }

    struct MessagesClearedEvent: Decodable, Sendable {
        let reason: WIConsoleClearReason?
    }

    struct ExecutionContextDescription: Decodable, Sendable {
        let id: Int
        let type: String
        let name: String
        let frameId: String?
    }

    struct ExecutionContextCreatedEvent: Decodable, Sendable {
        let context: ExecutionContextDescription
    }

    struct EvaluateResponse: Decodable, Sendable {
        let result: RemoteObject
        let wasThrown: Bool?
        let savedResultIndex: Int?
    }
}

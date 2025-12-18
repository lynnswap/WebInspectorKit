import Foundation
@testable import WebInspectorKit

enum NetworkTestHelpers {
    static func timePayload(monotonicMs: Double, wallMs: Double) -> [String: Any] {
        [
            "monotonicMs": monotonicMs,
            "wallMs": wallMs
        ]
    }

    static func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> HTTPNetworkEvent {
        guard let decoded = NetworkEventPayload(dictionary: payload),
              let event = HTTPNetworkEvent(payload: decoded, sessionID: sessionID) else {
            throw NetworkTestHelperError.invalidEvent
        }
        return event
    }

    static func decodeBatch(_ payload: [String: Any]) throws -> NetworkEventBatch {
        guard let batch = NetworkEventBatch.decode(from: payload) else {
            throw NetworkTestHelperError.invalidEvent
        }
        return batch
    }
}

enum NetworkTestHelperError: Error {
    case invalidEvent
}

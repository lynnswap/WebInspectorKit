import Foundation
@testable import WebInspectorEngine

public enum NetworkTestHelpers {
    public static func timePayload(monotonicMs: Double, wallMs: Double) -> [String: Any] {
        [
            "monotonicMs": monotonicMs,
            "wallMs": wallMs
        ]
    }

    public static func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> HTTPNetworkEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(NetworkEventPayload.self, from: data)
        guard let event = HTTPNetworkEvent(payload: decoded, sessionID: sessionID) else {
            throw NetworkTestHelperError.invalidEvent
        }
        return event
    }

    public static func decodeBatch(_ payload: [String: Any]) throws -> NetworkEventBatch {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(NetworkEventBatch.self, from: data)
    }
}

public enum NetworkTestHelperError: Error {
    case invalidEvent
}

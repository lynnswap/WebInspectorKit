import Foundation
@testable import WebInspectorEngine

public enum NetworkTestHelpers {
    public static func timePayload(monotonicMs: Double, wallMs: Double) -> [String: Any] {
        [
            "monotonicMs": monotonicMs,
            "wallMs": wallMs
        ]
    }

    public static func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> NetworkWire.PageHook.Event {
        _ = sessionID
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(NetworkWire.PageHook.Event.self, from: data)
    }

    public static func decodeBatch(_ payload: [String: Any]) throws -> NetworkWire.PageHook.Batch {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(NetworkWire.PageHook.Batch.self, from: data)
    }
}

public enum NetworkTestHelperError: Error {
    case invalidEvent
}

import Foundation
@testable import WebInspectorEngine

public enum NetworkTestHelpers {
    public static func timePayload(monotonicMs: Double, wallMs: Double) -> [String: Any] {
        [
            "monotonicMs": monotonicMs,
            "wallMs": wallMs
        ]
    }

    public static func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> NetworkEntry.Update {
        guard let kind = payload["kind"] as? String,
              let requestID = int(from: payload["requestId"]) else {
            throw NetworkTestHelperError.invalidEvent
        }

        switch kind {
        case "requestWillBeSent":
            return .requestStarted(
                .init(
                    requestID: requestID,
                    request: NetworkEntry.Request(
                        url: payload["url"] as? String ?? "",
                        method: (payload["method"] as? String)?.uppercased() ?? "UNKNOWN",
                        headers: NetworkHeaders(dictionary: stringDictionary(from: payload["headers"])),
                        body: body(from: payload["body"], role: .request),
                        bodyBytesSent: int(from: payload["bodySize"])
                            ?? body(from: payload["body"], role: .request)?.size,
                        type: payload["initiator"] as? String,
                        wallTime: wallTimeSeconds(from: payload, key: "time")
                    ),
                    timestamp: timeSeconds(from: payload, key: "time") ?? 0
                )
            )
        case "responseReceived":
            return .responseReceived(
                .init(
                    requestID: requestID,
                    response: response(from: payload, body: nil, errorDescription: nil),
                    requestType: payload["initiator"] as? String,
                    timestamp: timeSeconds(from: payload, key: "time") ?? 0
                )
            )
        case "loadingFinished":
            let responseBody = body(from: payload["body"], role: .response)
            return .completed(
                .init(
                    requestID: requestID,
                    response: response(from: payload, body: responseBody, errorDescription: nil),
                    requestType: payload["initiator"] as? String,
                    timestamp: timeSeconds(from: payload, key: "time") ?? 0,
                    encodedBodyLength: int(from: payload["encodedBodyLength"]),
                    decodedBodyLength: int(from: payload["decodedBodySize"]) ?? responseBody?.size
                )
            )
        case "loadingFailed":
            return .failed(
                .init(
                    requestID: requestID,
                    response: response(
                        from: payload,
                        body: nil,
                        errorDescription: errorMessage(from: payload["error"]) ?? ""
                    ),
                    requestType: payload["initiator"] as? String,
                    timestamp: timeSeconds(from: payload, key: "time") ?? 0
                )
            )
        case "resourceTiming":
            let responseBody = body(from: payload["body"], role: .response)
            return .resourceTimingSnapshot(
                .init(
                    requestID: requestID,
                    request: NetworkEntry.Request(
                        url: payload["url"] as? String ?? "",
                        method: (payload["method"] as? String)?.uppercased() ?? "GET",
                        headers: NetworkHeaders(),
                        body: nil,
                        bodyBytesSent: nil,
                        type: payload["initiator"] as? String,
                        wallTime: wallTimeSeconds(from: payload, key: "startTime")
                            ?? wallTimeSeconds(from: payload, key: "time")
                    ),
                    response: response(from: payload, body: responseBody, errorDescription: nil),
                    startTimestamp: timeSeconds(from: payload, key: "startTime")
                        ?? timeSeconds(from: payload, key: "time")
                        ?? 0,
                    endTimestamp: timeSeconds(from: payload, key: "endTime"),
                    encodedBodyLength: int(from: payload["encodedBodyLength"]),
                    decodedBodyLength: int(from: payload["decodedBodySize"]) ?? responseBody?.size
                )
            )
        default:
            throw NetworkTestHelperError.invalidEvent
        }
    }
}

public enum NetworkTestHelperError: Error {
    case invalidEvent
}

private extension NetworkTestHelpers {
    static func response(
        from payload: [String: Any],
        body: NetworkBody?,
        errorDescription: String?
    ) -> NetworkEntry.Response {
        NetworkEntry.Response(
            statusCode: int(from: payload["status"]),
            statusText: payload["statusText"] as? String ?? "",
            mimeType: payload["mimeType"] as? String,
            headers: NetworkHeaders(dictionary: stringDictionary(from: payload["headers"])),
            body: body,
            blockedCookies: [],
            errorDescription: errorDescription
        )
    }

    static func body(from value: Any?, role: NetworkBody.Role) -> NetworkBody? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        let kind = NetworkBody.Kind(rawValue: (dictionary["kind"] as? String ?? "").lowercased()) ?? .other
        let encoding = (dictionary["encoding"] as? String ?? "").lowercased()
        let preview = dictionary["preview"] as? String
            ?? dictionary["body"] as? String
            ?? dictionary["inlineBody"] as? String
        let full = dictionary["content"] as? String
            ?? dictionary["storageBody"] as? String
            ?? dictionary["fullBody"] as? String
        let formEntries: [NetworkBody.FormEntry] = (dictionary["formEntries"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String,
                  let value = entry["value"] as? String,
                  !name.isEmpty || !value.isEmpty else {
                return nil
            }
            return NetworkBody.FormEntry(
                name: name,
                value: value,
                isFile: entry["isFile"] as? Bool ?? false,
                fileName: entry["fileName"] as? String
            )
        }
        return NetworkBody(
            kind: kind,
            preview: preview,
            full: full,
            size: int(from: dictionary["size"]),
            isBase64Encoded: dictionary["base64Encoded"] as? Bool
                ?? dictionary["base64encoded"] as? Bool
                ?? (encoding == "base64"),
            isTruncated: dictionary["truncated"] as? Bool ?? false,
            summary: dictionary["summary"] as? String,
            formEntries: formEntries,
            role: role
        )
    }

    static func stringDictionary(from value: Any?) -> [String: String] {
        if let dictionary = value as? [String: String] {
            return dictionary
        }
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }
        return dictionary.reduce(into: [:]) { result, element in
            result[element.key] = String(describing: element.value)
        }
    }

    static func timeSeconds(from payload: [String: Any], key: String) -> TimeInterval? {
        timeValue(from: payload[key], field: "monotonicMs").map { $0 / 1000.0 }
    }

    static func wallTimeSeconds(from payload: [String: Any], key: String) -> TimeInterval? {
        timeValue(from: payload[key], field: "wallMs").map { $0 / 1000.0 }
    }

    static func timeValue(from value: Any?, field: String) -> Double? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        return double(from: dictionary[field])
    }

    static func errorMessage(from value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        return dictionary["message"] as? String
    }

    static func int(from value: Any?) -> Int? {
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
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded(.towardZero) == doubleValue else {
                return nil
            }
            return Int(doubleValue)
        }
        if let value = value as? Double {
            guard value.isFinite, value.rounded(.towardZero) == value else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    static func double(from value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }
}

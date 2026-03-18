import Foundation

package enum NetworkWire {}

package extension NetworkWire {
    enum PageHook {
        package enum Kind: String, Decodable {
            case requestWillBeSent
            case responseReceived
            case loadingFinished
            case loadingFailed
            case resourceTiming
        }

        package struct Time: Decodable {
            package let monotonicMs: Double
            package let wallMs: Double
        }

        package struct Error: Decodable {
            package let domain: String
            package let code: String?
            package let message: String
            package let isCanceled: Bool?
            package let isTimeout: Bool?
        }

        package struct Event: Decodable {
            package let kind: String
            package let requestId: Int
            package let time: Time?
            package let startTime: Time?
            package let endTime: Time?
            package let url: String?
            package let method: String?
            package let status: Int?
            package let statusText: String?
            package let mimeType: String?
            package let headers: [String: String]?
            package let initiator: String?
            package let body: NetworkBodyPayload?
            package let bodySize: Int?
            package let encodedBodyLength: Int?
            package let decodedBodySize: Int?
            package let error: Error?

            package var kindValue: Kind? {
                Kind(rawValue: kind)
            }

            package var normalizedMethod: String? {
                method?.uppercased()
            }
        }

        package struct Batch: Decodable {
            package let version: Int
            package let sessionID: String
            package let seq: Int
            package let events: [Event]
            package let dropped: Int?

            private enum CodingKeys: String, CodingKey {
                case version
                case schemaVersion
                case sessionId
                case seq
                case events
                case dropped
            }

            package init(
                version: Int,
                sessionID: String,
                seq: Int,
                events: [Event],
                dropped: Int?
            ) {
                self.version = version
                self.sessionID = sessionID
                self.seq = seq
                self.events = events
                self.dropped = dropped
            }

            package init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                let legacyVersion = try container.decodeIfPresent(Int.self, forKey: .version)
                let sessionID = try container.decode(String.self, forKey: .sessionId)
                let payloads = try container.decode([Event].self, forKey: .events)
                    .filter { $0.kindValue != nil }

                guard !payloads.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .events,
                        in: container,
                        debugDescription: "No valid network events"
                    )
                }

                self.version = schemaVersion ?? legacyVersion ?? 1
                self.sessionID = sessionID
                self.seq = try container.decodeIfPresent(Int.self, forKey: .seq) ?? 0
                self.events = payloads
                self.dropped = try container.decodeIfPresent(Int.self, forKey: .dropped)
            }

            package static func decode(from payload: Any?) -> Batch? {
                if let data = payload as? Data {
                    return decode(fromData: data)
                }
                if let jsonString = payload as? String,
                   let data = jsonString.data(using: .utf8) {
                    return decode(fromData: data)
                }
                if let dictionary = payload as? NSDictionary {
                    return decode(fromDictionary: dictionary)
                }
                return nil
            }

            private static func decode(fromData data: Data) -> Batch? {
                if let batch = try? JSONDecoder().decode(Batch.self, from: data) {
                    return batch
                }
                guard let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = object as? NSDictionary else {
                    return nil
                }
                return decode(fromDictionary: dictionary)
            }

            private static func decode(fromDictionary dictionary: NSDictionary) -> Batch? {
                if let data = try? JSONSerialization.data(withJSONObject: dictionary),
                   let batch = try? JSONDecoder().decode(Batch.self, from: data) {
                    return batch
                }

                let version = dictionary["schemaVersion"] as? Int ?? dictionary["version"] as? Int ?? 1
                let sessionID = dictionary["sessionId"] as? String ?? ""
                let seq = dictionary["seq"] as? Int ?? 0
                let dropped = dictionary["dropped"] as? Int
                let rawEvents = dictionary["events"] as? NSArray ?? []
                var events: [Event] = []
                events.reserveCapacity(rawEvents.count)

                for rawEvent in rawEvents {
                    guard let payload = decodeEvent(from: rawEvent),
                          payload.kindValue != nil else {
                        continue
                    }
                    events.append(payload)
                }

                guard !events.isEmpty else {
                    return nil
                }

                return Batch(
                    version: version,
                    sessionID: sessionID,
                    seq: seq,
                    events: events,
                    dropped: dropped
                )
            }

            private static func decodeEvent(from rawEvent: Any) -> Event? {
                if let payload = rawEvent as? Event {
                    return payload
                }
                if let dictionary = rawEvent as? NSDictionary {
                    if let payload = Event(dictionary: dictionary) {
                        return payload
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: dictionary) {
                        return try? JSONDecoder().decode(Event.self, from: data)
                    }
                }
                if let jsonString = rawEvent as? String,
                   let data = jsonString.data(using: .utf8) {
                    return try? JSONDecoder().decode(Event.self, from: data)
                }
                if let data = rawEvent as? Data {
                    return try? JSONDecoder().decode(Event.self, from: data)
                }
                return nil
            }
        }
    }
}

private extension NetworkWire.PageHook.Time {
    init?(dictionary: NSDictionary) {
        guard let monotonicMs = networkDouble(from: dictionary["monotonicMs"]),
              let wallMs = networkDouble(from: dictionary["wallMs"]) else {
            return nil
        }
        self.init(monotonicMs: monotonicMs, wallMs: wallMs)
    }
}

private extension NetworkWire.PageHook.Error {
    init?(dictionary: NSDictionary) {
        guard let domain = dictionary["domain"] as? String,
              let message = dictionary["message"] as? String else {
            return nil
        }
        self.init(
            domain: domain,
            code: dictionary["code"] as? String,
            message: message,
            isCanceled: dictionary["isCanceled"] as? Bool,
            isTimeout: dictionary["isTimeout"] as? Bool
        )
    }
}

private extension NetworkWire.PageHook.Event {
    init?(dictionary: NSDictionary) {
        guard let kind = dictionary["kind"] as? String,
              let requestId = networkInt(from: dictionary["requestId"]) else {
            return nil
        }

        let time = (dictionary["time"] as? NSDictionary).flatMap(NetworkWire.PageHook.Time.init(dictionary:))
        let startTime = (dictionary["startTime"] as? NSDictionary).flatMap(NetworkWire.PageHook.Time.init(dictionary:))
        let endTime = (dictionary["endTime"] as? NSDictionary).flatMap(NetworkWire.PageHook.Time.init(dictionary:))

        let headers = dictionary["headers"] as? [String: String]
            ?? (dictionary["headers"] as? NSDictionary).map { rawHeaders in
                var mapped: [String: String] = [:]
                for (key, value) in rawHeaders {
                    mapped[String(describing: key)] = String(describing: value)
                }
                return mapped
            }

        let bodyPayload: NetworkBodyPayload?
        if let body = dictionary["body"] as? NSDictionary {
            bodyPayload = NetworkBodyPayload(dictionary: body)
        } else {
            bodyPayload = nil
        }

        let errorPayload = (dictionary["error"] as? NSDictionary).flatMap(NetworkWire.PageHook.Error.init(dictionary:))

        self.init(
            kind: kind,
            requestId: requestId,
            time: time,
            startTime: startTime,
            endTime: endTime,
            url: dictionary["url"] as? String,
            method: dictionary["method"] as? String,
            status: networkInt(from: dictionary["status"]),
            statusText: dictionary["statusText"] as? String,
            mimeType: dictionary["mimeType"] as? String,
            headers: headers,
            initiator: dictionary["initiator"] as? String,
            body: bodyPayload,
            bodySize: networkInt(from: dictionary["bodySize"]),
            encodedBodyLength: networkInt(from: dictionary["encodedBodyLength"]),
            decodedBodySize: networkInt(from: dictionary["decodedBodySize"]),
            error: errorPayload
        )
    }
}

private func networkDouble(from value: Any?) -> Double? {
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

private func networkInt(from value: Any?) -> Int? {
    if value is Bool {
        return nil
    }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return nil
        }
        return networkIntegralInt(from: value.doubleValue)
    }
    if let value = value as? Int {
        return value
    }
    if let value = value as? String {
        return Int(value)
    }
    if let value = value as? Double {
        return networkIntegralInt(from: value)
    }
    return nil
}

private func networkIntegralInt(from value: Double) -> Int? {
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

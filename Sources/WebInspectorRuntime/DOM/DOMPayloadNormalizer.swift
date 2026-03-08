import Foundation
import WebInspectorEngine

@MainActor
final class DOMPayloadNormalizer {
    func selectionPayload(from payload: Any) -> DOMSelectionSnapshotPayload? {
        guard let object = objectPayload(from: payload), !object.isEmpty else {
            return nil
        }

        let nodeID = intValue(object["nodeId"]) ?? intValue(object["id"])
        let preview = stringValue(object["preview"]) ?? ""
        let attributes = normalizeSelectionAttributes(object["attributes"], nodeID: nodeID)
        let path = arrayValue(object["path"])?.compactMap(stringValue) ?? []
        let selectorPath = stringValue(object["selectorPath"]) ?? ""
        let styleRevision = intValue(object["styleRevision"]) ?? 0

        return DOMSelectionSnapshotPayload(
            nodeID: nodeID,
            preview: preview,
            attributes: attributes,
            path: path,
            selectorPath: selectorPath,
            styleRevision: styleRevision
        )
    }

    func selectorPayload(from payload: Any) -> DOMSelectorPathPayload? {
        guard let object = objectPayload(from: payload) else {
            return nil
        }

        let nodeID = intValue(object["nodeId"]) ?? intValue(object["id"])
        let selectorPath = stringValue(object["selectorPath"]) ?? ""
        return DOMSelectorPathPayload(nodeID: nodeID, selectorPath: selectorPath)
    }
}

private extension DOMPayloadNormalizer {
    func objectPayload(from payload: Any?) -> [String: Any]? {
        if let object = dictionaryValue(payload) {
            return object
        }

        if let json = payload as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           let object = dictionaryValue(decoded) {
            return object
        }

        return nil
    }

    func normalizeSelectionAttributes(_ payload: Any?, nodeID: Int?) -> [DOMAttribute] {
        guard let values = arrayValue(payload) else {
            return []
        }

        return values.compactMap { entry in
            guard let object = dictionaryValue(entry),
                  let name = stringValue(object["name"]) else {
                return nil
            }

            let value = stringValue(object["value"]) ?? ""
            return DOMAttribute(nodeId: nodeID, name: name, value: value)
        }
    }

    func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] {
            return value
        }
        if let value = value as? NSDictionary {
            var result: [String: Any] = [:]
            result.reserveCapacity(value.count)
            for (rawKey, rawValue) in value {
                guard let key = rawKey as? String else {
                    return nil
                }
                result[key] = rawValue
            }
            return result
        }
        return nil
    }

    func arrayValue(_ value: Any?) -> [Any]? {
        if let value = value as? [Any] {
            return value
        }
        if let value = value as? NSArray {
            return value.map { $0 }
        }
        return nil
    }

    func stringValue(_ value: Any?) -> String? {
        if value is NSNull {
            return nil
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return String(value)
        }
        return nil
    }

    func intValue(_ value: Any?) -> Int? {
        if value is Bool {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? UInt64 {
            guard value <= UInt64(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? UInt {
            guard value <= UInt(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? Int64 {
            guard value >= Int64(Int.min), value <= Int64(Int.max) else {
                return nil
            }
            return Int(value)
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return nil
            }
            let doubleValue = value.doubleValue
            guard doubleValue.isFinite else {
                return nil
            }
            let truncated = doubleValue.rounded(.towardZero)
            guard truncated == doubleValue else {
                return nil
            }
            guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
                return nil
            }
            return Int(truncated)
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}

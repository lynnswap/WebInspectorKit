import Foundation

public struct NetworkJSONNode: Identifiable, Sendable {
    fileprivate enum JSONValue: Sendable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    public enum DisplayKind: Sendable {
        case object(count: Int)
        case array(count: Int)
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    public let id = UUID()
    public let key: String
    public let isIndex: Bool
    private let value: JSONValue
    public let children: [NetworkJSONNode]?

    public var displayKind: DisplayKind {
        switch value {
        case .object(let dictionary):
            return .object(count: dictionary.count)
        case .array(let array):
            return .array(count: array.count)
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .number(value)
        case .bool(let value):
            return .bool(value)
        case .null:
            return .null
        }
    }

    private init(key: String, value: JSONValue, isIndex: Bool) {
        self.key = key
        self.isIndex = isIndex
        self.value = value
        self.children = NetworkJSONNode.makeChildren(from: value)
    }

    public static func nodes(from text: String) -> [NetworkJSONNode]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return nodes(from: object)
    }

    private static func nodes(from object: Any) -> [NetworkJSONNode] {
        let value = JSONValue.make(from: object)
        return makeChildren(from: value) ?? [NetworkJSONNode(key: "", value: value, isIndex: false)]
    }

    private static func makeChildren(from value: JSONValue) -> [NetworkJSONNode]? {
        switch value {
        case .object(let dictionary):
            if dictionary.isEmpty {
                return nil
            }
            let keys = Array(dictionary.keys)
            return keys.map { key in
                NetworkJSONNode(key: key, value: dictionary[key] ?? .null, isIndex: false)
            }
        case .array(let array):
            if array.isEmpty {
                return nil
            }
            return array.enumerated().map { index, item in
                NetworkJSONNode(key: String(index), value: item, isIndex: true)
            }
        default:
            return nil
        }
    }

    private static func truncate(_ value: String, limit: Int = 160) -> String {
        guard value.count > limit else {
            return value
        }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }
}

private extension NetworkJSONNode.JSONValue {
    static func make(from object: Any) -> NetworkJSONNode.JSONValue {
        if let dictionary = object as? NSDictionary {
            var mapped: [String: NetworkJSONNode.JSONValue] = [:]
            dictionary.forEach { key, value in
                if let key = key as? String {
                    mapped[key] = make(from: value)
                }
            }
            return .object(mapped)
        }
        if let array = object as? NSArray {
            return .array(array.map { make(from: $0) })
        }
        if let string = object as? String {
            return .string(string)
        }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(String(describing: number))
        }
        if object is NSNull {
            return .null
        }
        return .string(String(describing: object))
    }
}

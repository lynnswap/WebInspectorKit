import Foundation

struct WINetworkJSONNode: Identifiable {
    fileprivate enum JSONValue {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    enum DisplayKind {
        case object(count: Int)
        case array(count: Int)
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    let id = UUID()
    let key: String
    let isIndex: Bool
    private let value: JSONValue
    let children: [WINetworkJSONNode]?

    var displayKind: DisplayKind {
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
        self.children = WINetworkJSONNode.makeChildren(from: value)
    }

    static func nodes(from text: String) -> [WINetworkJSONNode]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return nodes(from: object)
    }

    private static func nodes(from object: Any) -> [WINetworkJSONNode] {
        let value = JSONValue.make(from: object)
        return makeChildren(from: value) ?? [WINetworkJSONNode(key: "", value: value, isIndex: false)]
    }

    private static func makeChildren(from value: JSONValue) -> [WINetworkJSONNode]? {
        switch value {
        case .object(let dictionary):
            if dictionary.isEmpty {
                return nil
            }
            let keys = Array(dictionary.keys)
            return keys.map { key in
                WINetworkJSONNode(key: key, value: dictionary[key] ?? .null, isIndex: false)
            }
        case .array(let array):
            if array.isEmpty {
                return nil
            }
            return array.enumerated().map { index, item in
                WINetworkJSONNode(key: String(index), value: item, isIndex: true)
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

private extension WINetworkJSONNode.JSONValue {
    static func make(from object: Any) -> WINetworkJSONNode.JSONValue {
        if let dictionary = object as? [String: Any] {
            var mapped: [String: WINetworkJSONNode.JSONValue] = [:]
            dictionary.forEach { key, value in
                mapped[key] = make(from: value)
            }
            return .object(mapped)
        }
        if let array = object as? [Any] {
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

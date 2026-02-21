import Foundation
import WebInspectorKitCore

enum NetworkBodyPreviewTreeMenuSupport {
    struct PathComponent: Equatable, Sendable {
        let key: String
        let isIndex: Bool
    }

    static func propertyPathString(from components: [PathComponent]) -> String {
        guard !components.isEmpty else {
            return "this"
        }

        var path = "this"
        for component in components {
            if component.isIndex {
                if Int(component.key) != nil {
                    path += "[\(component.key)]"
                } else {
                    path += "[\(quotedJSONStringLiteral(component.key))]"
                }
                continue
            }

            if isValidJavaScriptIdentifier(component.key) {
                path += ".\(component.key)"
            } else {
                path += "[\(quotedJSONStringLiteral(component.key))]"
            }
        }
        return path
    }

    static func scalarCopyText(for node: NetworkJSONNode) -> String? {
        switch node.displayKind {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .object, .array:
            return nil
        }
    }

    static func subtreeCopyText(for node: NetworkJSONNode) -> String? {
        let value = foundationValue(for: node)
        if JSONSerialization.isValidJSONObject(value) {
            guard
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
                let text = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return text
        }
        return jsonLiteral(for: value)
    }

    private static func foundationValue(for node: NetworkJSONNode) -> Any {
        switch node.displayKind {
        case .object:
            var dictionary: [String: Any] = [:]
            for child in node.children ?? [] {
                dictionary[child.key] = foundationValue(for: child)
            }
            return dictionary
        case .array:
            let sortedChildren = (node.children ?? []).sorted { lhs, rhs in
                if let left = Int(lhs.key), let right = Int(rhs.key) {
                    return left < right
                }
                return lhs.key < rhs.key
            }
            return sortedChildren.map { foundationValue(for: $0) }
        case .string(let value):
            return value
        case .number(let value):
            return foundationNumber(from: value)
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    private static func foundationNumber(from value: String) -> Any {
        if let intValue = Int64(value) {
            return NSNumber(value: intValue)
        }
        if let uintValue = UInt64(value) {
            return NSNumber(value: uintValue)
        }
        if let doubleValue = Double(value), doubleValue.isFinite {
            return NSNumber(value: doubleValue)
        }
        let decimal = NSDecimalNumber(string: value)
        if decimal != NSDecimalNumber.notANumber {
            return decimal
        }
        return value
    }

    private static func jsonLiteral(for value: Any) -> String? {
        if let stringValue = value as? String {
            return quotedJSONStringLiteral(stringValue)
        }
        if let numberValue = value as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return numberValue.boolValue ? "true" : "false"
            }
            return numberValue.stringValue
        }
        if value is NSNull {
            return "null"
        }
        return nil
    }

    private static func quotedJSONStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
            let encoded = String(data: data, encoding: .utf8),
            encoded.count >= 2
        else {
            return "\"\(value)\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    private static func isValidJavaScriptIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first else {
            return false
        }

        let firstCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$")
        let tailCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$")

        guard firstCharacterSet.contains(first) else {
            return false
        }

        for scalar in value.unicodeScalars.dropFirst() {
            if !tailCharacterSet.contains(scalar) {
                return false
            }
        }
        return true
    }
}

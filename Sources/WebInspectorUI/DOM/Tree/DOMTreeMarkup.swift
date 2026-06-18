#if canImport(UIKit)
import Foundation
import WebInspectorCore

extension DOMTreeTextView {
    struct Markup: Sendable {
        private(set) var text = ""
        private(set) var utf16Length = 0
        private(set) var displayColumnCount = 0
        private(set) var tokens: [DOMTreeTextView.Token] = []

        mutating func append(_ fragment: String, kind: DOMTreeTextView.Token.Kind) {
            guard !fragment.isEmpty else {
                return
            }
            let metrics = domTreeTextMetrics(for: fragment)
            let start = utf16Length
            text += fragment
            utf16Length += metrics.utf16Length
            displayColumnCount += metrics.displayColumnCount
            tokens.append(
                DOMTreeTextView.Token(
                    kind: kind,
                    range: NSRange(location: start, length: metrics.utf16Length)
                )
            )
        }

        mutating func appendQuotedAttributeValue(_ value: String) {
            append("\"", kind: .attributeValue)
            append(value, kind: .attributeValue)
            append("\"", kind: .attributeValue)
        }

        mutating func appendQuotedText(_ value: String) {
            append("\"", kind: .punctuation)
            append(value, kind: .text)
            append("\"", kind: .punctuation)
        }
    }
}

private struct DOMTreeTextMetrics {
    let utf16Length: Int
    let displayColumnCount: Int
}

private func domTreeTextMetrics(for string: String) -> DOMTreeTextMetrics {
    var utf8Length = 0
    var asciiColumnCount = 0
    var isASCII = true

    for byte in string.utf8 {
        utf8Length += 1
        if byte < 0x80 {
            asciiColumnCount += domTreeASCIIColumnCount(for: byte)
        } else {
            isASCII = false
            break
        }
    }

    if isASCII {
        return DOMTreeTextMetrics(
            utf16Length: utf8Length,
            displayColumnCount: asciiColumnCount
        )
    }

    var utf16Length = 0
    var displayColumnCount = 0
    for scalar in string.unicodeScalars {
        utf16Length += scalar.value > 0xFFFF ? 2 : 1
        displayColumnCount += domTreeDisplayColumnCount(for: scalar)
    }
    return DOMTreeTextMetrics(
        utf16Length: utf16Length,
        displayColumnCount: displayColumnCount
    )
}

private func domTreeASCIIColumnCount(for byte: UInt8) -> Int {
    switch byte {
    case 0x09:
        return 4
    case 0x0A, 0x0D:
        return 0
    default:
        return 1
    }
}

private func domTreeDisplayColumnCount(for scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0x09:
        return 4
    case 0x0A, 0x0D:
        return 0
    case 0xFE00...0xFE0F, 0xE0100...0xE01EF, 0x200B, 0x200D:
        return 0
    default:
        break
    }

    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
        return 0
    case .control, .format:
        return 0
    default:
        break
    }

    if scalar.isASCII {
        return 1
    }

    // Conservative non-ASCII sizing prevents full-width and fallback glyphs from being clipped
    // without returning to per-line glyph measurement on the main thread.
    return 2
}

extension DOMTreeTextView {
    @MainActor
    enum MarkupBuilder {
        private static let voidElementNames: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
        ]
        private static let booleanAttributeNames: Set<String> = [
            "allowfullscreen", "async", "autofocus", "autoplay", "checked", "controls", "default", "defer", "disabled",
            "formnovalidate", "hidden", "inert", "ismap", "itemscope", "loop", "multiple", "muted", "nomodule",
            "novalidate", "open", "playsinline", "readonly", "required", "reversed", "selected"
        ]

        static func markup(
            for node: DOMNode,
            hasDisclosure: Bool,
            isOpen: Bool,
            isClosingTag: Bool,
            isTemplateContent: Bool
        ) -> DOMTreeTextView.Markup {
            if isClosingTag {
                return closingElementMarkup(for: node)
            }

            switch inferredNodeType(for: node) {
            case .element:
                return elementMarkup(for: node, hasDisclosure: hasDisclosure, isOpen: isOpen)
            case .text:
                return textMarkup(for: node)
            case .comment:
                return commentMarkup(for: node)
            case .documentType:
                return documentTypeMarkup(for: node)
            case .documentFragment:
                return documentFragmentMarkup(for: node, isTemplateContent: isTemplateContent)
            case .cdataSection:
                return cdataMarkup(for: node)
            case .processingInstruction:
                return processingInstructionMarkup(for: node)
            case .document:
                return fallbackMarkup("#document")
            default:
                return fallbackMarkup(fallbackPreview(for: node))
            }
        }

        static func rendersClosingTagRow(for node: DOMNode) -> Bool {
            guard inferredNodeType(for: node) == .element else {
                return false
            }
            guard node.pseudoType == nil else {
                return false
            }
            return !voidElementNames.contains(elementName(for: node))
        }

        static func canContainChildNodes(_ node: DOMNode) -> Bool {
            switch inferredNodeType(for: node) {
            case .document, .documentFragment:
                return true
            case .element:
                return !voidElementNames.contains(elementName(for: node))
            default:
                return false
            }
        }

        private static func inferredNodeType(for node: DOMNode) -> DOMNode.Kind {
            let name = (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
            if node.nodeType != .element || name.isEmpty {
                return node.nodeType
            }

            switch name {
            case "#document":
                return .document
            case "!doctype", "#doctype":
                return .documentType
            case "#text":
                return .text
            case "#comment":
                return .comment
            case "#cdata-section":
                return .cdataSection
            case "#document-fragment", "#shadow-root":
                return .documentFragment
            case let name where !name.isEmpty && !name.hasPrefix("#"):
                return .element
            default:
                return node.nodeType
            }
        }

        private static func elementMarkup(for node: DOMNode, hasDisclosure: Bool, isOpen: Bool) -> DOMTreeTextView.Markup {
            if let pseudoType = node.pseudoType {
                return fallbackMarkup("::\(pseudoType)")
            }

            let name = elementName(for: node)
            let isVoid = voidElementNames.contains(name)
            var markup = DOMTreeTextView.Markup()
            markup.append("<", kind: .punctuation)
            markup.append(name, kind: .tagName)
            for attribute in node.attributes {
                append(attribute: attribute, to: &markup)
            }
            markup.append(">", kind: .punctuation)

            if !isVoid {
                if hasDisclosure, !isOpen {
                    markup.append("…", kind: .fallback)
                    markup.append("</", kind: .punctuation)
                    markup.append(name, kind: .tagName)
                    markup.append(">", kind: .punctuation)
                } else if !hasDisclosure {
                    markup.append("</", kind: .punctuation)
                    markup.append(name, kind: .tagName)
                    markup.append(">", kind: .punctuation)
                }
            }
            return markup
        }

        private static func closingElementMarkup(for node: DOMNode) -> DOMTreeTextView.Markup {
            let name = elementName(for: node)
            var markup = DOMTreeTextView.Markup()
            markup.append("</", kind: .punctuation)
            markup.append(name, kind: .tagName)
            markup.append(">", kind: .punctuation)
            return markup
        }

        private static func documentFragmentMarkup(for node: DOMNode, isTemplateContent: Bool) -> DOMTreeTextView.Markup {
            if let shadowRootType = node.shadowRootType {
                return fallbackMarkup("Shadow Content (\(shadowRootTypeDisplayName(shadowRootType)))")
            }
            if isTemplateContent {
                return fallbackMarkup("Template Content")
            }
            return fallbackMarkup("Document Fragment")
        }

        private static func shadowRootTypeDisplayName(_ rawValue: String) -> String {
            switch rawValue.lowercased() {
            case "user-agent", "useragent":
                "User Agent"
            case "open":
                "Open"
            case "closed":
                "Closed"
            default:
                rawValue
            }
        }

        private static func append(attribute: DOMNode.Attribute, to markup: inout DOMTreeTextView.Markup) {
            let name = attribute.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return
            }
            markup.append(" ", kind: .fallback)
            markup.append(name, kind: .attributeName)
            guard !isBooleanAttribute(attribute) else {
                return
            }
            markup.append("=", kind: .attributeValue)
            markup.appendQuotedAttributeValue(escapedAttributeValue(attribute.value))
        }

        private static func textMarkup(for node: DOMNode) -> DOMTreeTextView.Markup {
            let text = escapedTextValue(normalizedValue(for: node))
            guard !text.isEmpty else {
                return fallbackMarkup("#text")
            }
            var markup = DOMTreeTextView.Markup()
            markup.appendQuotedText(text)
            return markup
        }

        private static func commentMarkup(for node: DOMNode) -> DOMTreeTextView.Markup {
            var markup = DOMTreeTextView.Markup()
            markup.append("<!--", kind: .punctuation)
            let text = escapedCommentValue(normalizedValue(for: node))
            if !text.isEmpty {
                markup.append(" ", kind: .fallback)
                markup.append(text, kind: .comment)
                markup.append(" ", kind: .fallback)
            }
            markup.append("-->", kind: .punctuation)
            return markup
        }

        private static func documentTypeMarkup(for node: DOMNode) -> DOMTreeTextView.Markup {
            var markup = DOMTreeTextView.Markup()
            let name = elementName(for: node, fallback: "html")
            markup.append("<!", kind: .punctuation)
            markup.append("DOCTYPE", kind: .doctype)
            markup.append(" ", kind: .fallback)
            markup.append(name, kind: .doctype)
            markup.append(">", kind: .punctuation)
            return markup
        }

        private static func cdataMarkup(for node: DOMNode) -> DOMTreeTextView.Markup {
            var markup = DOMTreeTextView.Markup()
            markup.append("<![CDATA[", kind: .punctuation)
            markup.append(lineSafeValue(normalizedValue(for: node)), kind: .text)
            markup.append("]]>", kind: .punctuation)
            return markup
        }

        private static func processingInstructionMarkup(for node: DOMNode) -> DOMTreeTextView.Markup {
            var markup = DOMTreeTextView.Markup()
            markup.append("<?", kind: .punctuation)
            markup.append(elementName(for: node, fallback: "instruction"), kind: .tagName)
            let text = lineSafeValue(normalizedValue(for: node))
            if !text.isEmpty {
                markup.append(" ", kind: .fallback)
                markup.append(text, kind: .text)
            }
            markup.append("?>", kind: .punctuation)
            return markup
        }

        private static func fallbackMarkup(_ text: String) -> DOMTreeTextView.Markup {
            var markup = DOMTreeTextView.Markup()
            markup.append(text.isEmpty ? "(empty)" : lineSafeValue(text), kind: .fallback)
            return markup
        }

        private static func isBooleanAttribute(_ attribute: DOMNode.Attribute) -> Bool {
            attribute.value.isEmpty && booleanAttributeNames.contains(attribute.name.lowercased())
        }

        private static func elementName(for node: DOMNode, fallback: String = "element") -> String {
            let rawName: String
            if !node.localName.isEmpty {
                rawName = node.localName
            } else if !node.nodeName.isEmpty {
                rawName = node.nodeName
            } else {
                rawName = fallback
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name.isEmpty ? fallback : name).lowercased()
        }

        private static func fallbackPreview(for node: DOMNode) -> String {
            if !node.nodeValue.isEmpty {
                return node.nodeValue
            }
            if !node.localName.isEmpty {
                return node.localName
            }
            return node.nodeName
        }

        private static func normalizedValue(for node: DOMNode) -> String {
            let source = node.nodeValue.isEmpty ? node.nodeName : node.nodeValue
            return source
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func escapedAttributeValue(_ value: String) -> String {
            lineSafeValue(value)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        private static func escapedTextValue(_ value: String) -> String {
            lineSafeValue(value)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        private static func escapedCommentValue(_ value: String) -> String {
            lineSafeValue(value)
                .replacingOccurrences(of: "-->", with: "--\\>")
        }

        private static func lineSafeValue(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
#endif

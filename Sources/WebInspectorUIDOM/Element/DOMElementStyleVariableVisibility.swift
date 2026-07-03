#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
package enum DOMElementStyleVariableVisibility {
    package static func hiddenUnusedVariableIndices(
        in section: CSSStyleSection,
        usedCSSVariables: Set<String>
    ) -> Set<Int> {
        guard isInheritedStyleSection(section) else {
            return []
        }
        return Set(section.style.properties.enumerated().compactMap { index, property in
            guard property.isEnabled,
                  isCSSVariable(property.name),
                  !usedCSSVariables.contains(property.name) else {
                return nil
            }
            return index
        })
    }

    package static func usedCSSVariableNames(in sections: [CSSStyleSection]) -> Set<String> {
        var usedVariables = Set<String>()
        for section in sections {
            for property in section.style.properties where contributesCSSVariableUsage(property) {
                if isCSSVariable(property.name) {
                    continue
                }
                usedVariables.formUnion(cssVariableReferences(in: property.value))
            }
        }

        var addedReferences = true
        while addedReferences {
            addedReferences = false
            for section in sections {
                for property in section.style.properties
                where contributesCSSVariableUsage(property)
                    && isCSSVariable(property.name)
                    && usedVariables.contains(property.name) {
                    for variable in cssVariableReferences(in: property.value) where usedVariables.insert(variable).inserted {
                        addedReferences = true
                    }
                }
            }
        }

        return usedVariables
    }

    private static func isInheritedStyleSection(_ section: CSSStyleSection) -> Bool {
        switch section.kind {
        case .inheritedInlineStyle, .inheritedRule:
            true
        case .inlineStyle, .rule, .attributesStyle, .pseudoElement:
            false
        }
    }

    private static func isCSSVariable(_ name: String) -> Bool {
        name.hasPrefix("--")
    }

    private static func contributesCSSVariableUsage(_ property: CSS.Property) -> Bool {
        property.isEnabled && !property.isOverridden
    }

    private static func cssVariableReferences(in value: String) -> Set<String> {
        var references = Set<String>()
        var index = value.startIndex
        var quotedString: Character?
        var isEscaped = false
        var isComment = false

        while index < value.endIndex {
            let character = value[index]
            let nextIndex = value.index(after: index)
            let nextCharacter = nextIndex < value.endIndex ? value[nextIndex] : nil

            if isComment {
                if character == "*", nextCharacter == "/" {
                    isComment = false
                    index = value.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }

            if let quote = quotedString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == quote {
                    quotedString = nil
                }
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "*" {
                isComment = true
                index = value.index(after: nextIndex)
                continue
            }
            if character == "\"" || character == "'" {
                quotedString = character
                index = nextIndex
                continue
            }

            guard hasCSSFunctionBoundary(before: index, in: value),
                  startsCSSVariableFunction(in: value, at: index) else {
                index = nextIndex
                continue
            }

            let argumentStart = value.index(index, offsetBy: 4)
            var referenceStart = argumentStart
            while referenceStart < value.endIndex, value[referenceStart].isWhitespace {
                value.formIndex(after: &referenceStart)
            }

            if value[referenceStart...].hasPrefix("--") {
                var end = referenceStart
                while end < value.endIndex, isCSSVariableNameCharacter(value[end]) {
                    value.formIndex(after: &end)
                }
                if end > referenceStart {
                    references.insert(String(value[referenceStart..<end]))
                }
            }

            index = argumentStart
        }

        return references
    }

    private static func hasCSSFunctionBoundary(before index: String.Index, in value: String) -> Bool {
        guard index > value.startIndex else {
            return true
        }
        return !isCSSIdentifierCharacter(value[value.index(before: index)])
    }

    private static func startsCSSVariableFunction(in value: String, at index: String.Index) -> Bool {
        var cursor = index
        guard cursor < value.endIndex,
              isASCIILetter(value[cursor], lowercaseValue: 118) else {
            return false
        }
        value.formIndex(after: &cursor)

        guard cursor < value.endIndex,
              isASCIILetter(value[cursor], lowercaseValue: 97) else {
            return false
        }
        value.formIndex(after: &cursor)

        guard cursor < value.endIndex,
              isASCIILetter(value[cursor], lowercaseValue: 114) else {
            return false
        }
        value.formIndex(after: &cursor)

        guard cursor < value.endIndex else {
            return false
        }
        return singleUnicodeScalarValue(value[cursor]) == 40
    }

    private static func isASCIILetter(_ character: Character, lowercaseValue: UInt32) -> Bool {
        guard let value = singleUnicodeScalarValue(character) else {
            return false
        }
        return value == lowercaseValue || value == lowercaseValue - 32
    }

    private static func singleUnicodeScalarValue(_ character: Character) -> UInt32? {
        var scalars = character.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(),
              scalars.next() == nil else {
            return nil
        }
        return scalar.value
    }

    private static func isCSSVariableNameCharacter(_ character: Character) -> Bool {
        isCSSIdentifierCharacter(character)
    }

    private static func isCSSIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}
#endif

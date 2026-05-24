#if canImport(UIKit)
import WebInspectorCore

@MainActor
package enum DOMElementStyleVariableVisibility {
    package static func hiddenUnusedVariableIndices(
        in section: CSSStyleSection,
        usedCSSVariables: Set<String>
    ) -> Set<Int> {
        guard isInheritedStyleSection(section) else {
            return []
        }
        return Set(section.style.cssProperties.enumerated().compactMap { index, property in
            guard property.isEnabled,
                  isCSSVariable(property.name),
                  !usedCSSVariables.contains(property.name) else {
                return nil
            }
            return index
        })
    }

    package static func usedCSSVariableNames(in nodeStyles: CSSNodeStyles) -> Set<String> {
        var usedVariables = Set<String>()
        for section in nodeStyles.sections {
            for property in section.style.cssProperties where contributesCSSVariableUsage(property) {
                if isInheritedStyleSection(section) && isCSSVariable(property.name) {
                    continue
                }
                usedVariables.formUnion(cssVariableReferences(in: property.value))
            }
        }

        var addedReferences = true
        while addedReferences {
            addedReferences = false
            for section in nodeStyles.sections where isInheritedStyleSection(section) {
                for property in section.style.cssProperties
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

    private static func contributesCSSVariableUsage(_ property: CSSProperty) -> Bool {
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

            guard value[index...].hasPrefix("var(") else {
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

    private static func isCSSVariableNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}
#endif

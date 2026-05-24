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
            for property in section.style.cssProperties where property.isEnabled {
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
                where property.isEnabled && isCSSVariable(property.name) && usedVariables.contains(property.name) {
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

    private static func cssVariableReferences(in value: String) -> Set<String> {
        var references = Set<String>()
        var searchRange = value.startIndex..<value.endIndex

        while let varFunctionRange = value.range(of: "var(", range: searchRange) {
            var index = varFunctionRange.upperBound
            while index < value.endIndex, value[index].isWhitespace {
                value.formIndex(after: &index)
            }

            if value[index...].hasPrefix("--") {
                var end = index
                while end < value.endIndex, isCSSVariableNameCharacter(value[end]) {
                    value.formIndex(after: &end)
                }
                if end > index {
                    references.insert(String(value[index..<end]))
                }
            }

            searchRange = varFunctionRange.upperBound..<value.endIndex
        }

        return references
    }

    private static func isCSSVariableNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}
#endif

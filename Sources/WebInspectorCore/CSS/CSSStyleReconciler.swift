import Foundation

extension CSSStyle {
    @MainActor
    enum Reconciler {
    private struct SectionMembership: Equatable {
        var id: CSSStyle.Section.ID
        var propertyIDs: [PropertyMembership]
    }

    private enum PropertyMembership: Equatable {
        case identified(CSSProperty.ID)
        case anonymous(index: Int)
    }

    static func updateSections(
        in nodeStyles: CSSNodeStyles,
        with refreshedSections: [CSSStyle.Section]
    ) {
        let oldMembership = sectionMembership(in: nodeStyles.sections)
        let existingSectionsByID = Dictionary(uniqueKeysWithValues: nodeStyles.sections.map { ($0.id, $0) })
        let reconciledSections = refreshedSections.map { refreshedSection in
            guard let existingSection = existingSectionsByID[refreshedSection.id] else {
                return refreshedSection
            }
            updateSection(existingSection, from: refreshedSection)
            return existingSection
        }

        if oldMembership != sectionMembership(in: reconciledSections) {
            nodeStyles.sections = reconciledSections
        }
    }

    static func updateStyle(_ style: CSSStyle, from refreshedStyle: CSSStyle) {
        style.id = refreshedStyle.id
        style.shorthandEntries = refreshedStyle.shorthandEntries
        style.cssText = refreshedStyle.cssText
        style.range = refreshedStyle.range
        style.width = refreshedStyle.width
        style.height = refreshedStyle.height
        style.isEditable = refreshedStyle.isEditable
        updateProperties(in: style, with: refreshedStyle.cssProperties)
    }

    static func updateComputedProperties(
        in nodeStyles: CSSNodeStyles,
        with refreshedProperties: [CSSComputedStyleProperty]
    ) {
        let existingPropertiesByName = Dictionary(uniqueKeysWithValues: nodeStyles.computedProperties.map { ($0.name, $0) })
        let oldNames = nodeStyles.computedProperties.map(\.name)
        let reconciledProperties = refreshedProperties.map { refreshedProperty in
            guard let existingProperty = existingPropertiesByName[refreshedProperty.name] else {
                return refreshedProperty
            }
            existingProperty.value = refreshedProperty.value
            return existingProperty
        }

        if oldNames != reconciledProperties.map(\.name) {
            nodeStyles.computedProperties = reconciledProperties
        }
    }

    private static func updateSection(_ section: CSSStyle.Section, from refreshedSection: CSSStyle.Section) {
        section.kind = refreshedSection.kind
        section.title = refreshedSection.title
        section.isEditable = refreshedSection.isEditable

        if let refreshedRule = refreshedSection.rule {
            if let rule = section.rule {
                updateRule(rule, from: refreshedRule)
                section.style = rule.style
            } else {
                section.rule = refreshedRule
                section.style = refreshedRule.style
            }
        } else {
            section.rule = nil
            updateStyle(section.style, from: refreshedSection.style)
        }
    }

    private static func updateRule(_ rule: CSSRule, from refreshedRule: CSSRule) {
        rule.id = refreshedRule.id
        rule.selectorList = refreshedRule.selectorList
        rule.sourceURL = refreshedRule.sourceURL
        rule.sourceLine = refreshedRule.sourceLine
        rule.styleSheetSourceLocation = refreshedRule.styleSheetSourceLocation
        rule.origin = refreshedRule.origin
        rule.groupings = refreshedRule.groupings
        rule.isImplicitlyNested = refreshedRule.isImplicitlyNested
        updateStyle(rule.style, from: refreshedRule.style)
    }

    private static func updateProperties(in style: CSSStyle, with refreshedProperties: [CSSProperty]) {
        let oldMembership = propertyMembership(in: style.cssProperties)
        let existingPropertiesByID = Dictionary(
            uniqueKeysWithValues: style.cssProperties.compactMap { property in
                property.id.map { ($0, property) }
            }
        )
        let reconciledProperties = refreshedProperties.enumerated().map { index, refreshedProperty in
            let existingProperty: CSSProperty?
            if let propertyID = refreshedProperty.id {
                existingProperty = existingPropertiesByID[propertyID]
            } else if style.cssProperties.indices.contains(index),
                      style.cssProperties[index].id == nil {
                existingProperty = style.cssProperties[index]
            } else {
                existingProperty = nil
            }

            guard let existingProperty else {
                return refreshedProperty
            }
            updateProperty(existingProperty, from: refreshedProperty)
            return existingProperty
        }

        if oldMembership != propertyMembership(in: reconciledProperties) {
            style.cssProperties = reconciledProperties
        }
    }

    private static func updateProperty(_ property: CSSProperty, from refreshedProperty: CSSProperty) {
        property.id = refreshedProperty.id
        property.name = refreshedProperty.name
        property.value = refreshedProperty.value
        property.priority = refreshedProperty.priority
        property.text = refreshedProperty.text
        property.parsedOk = refreshedProperty.parsedOk
        property.status = refreshedProperty.status
        property.implicit = refreshedProperty.implicit
        property.range = refreshedProperty.range
        property.isEditable = refreshedProperty.isEditable
        property.updateInspectorModificationState()
    }

    private static func sectionMembership(in sections: [CSSStyle.Section]) -> [SectionMembership] {
        sections.map { section in
            SectionMembership(
                id: section.id,
                propertyIDs: propertyMembership(in: section.style.cssProperties)
            )
        }
    }

    private static func propertyMembership(in properties: [CSSProperty]) -> [PropertyMembership] {
        properties.enumerated().map { index, property in
            if let propertyID = property.id {
                return .identified(propertyID)
            }
            return .anonymous(index: index)
        }
    }
    }
}

import Foundation
import Observation
import WebInspectorProxyKit

/// Pre-edit snapshot of a property row, recorded the first time the
/// inspector rewrites its declaration. A property is "modified by
/// inspector" while its current state differs from this baseline.
private struct CSSPropertyInspectorBaseline: Equatable {
    var name: String
    var value: String
    var priority: String?
    var text: String?
    var status: CSS.Status

    init(_ property: CSS.Property) {
        name = property.name
        value = property.value
        priority = property.priority
        text = property.text
        status = property.status
    }
}

@Observable
public final class CSSStyles: WebInspectorPersistentModel {
    public struct ID: Hashable, Sendable {
        let nodeID: DOMNode.ID

        init(nodeID: DOMNode.ID) {
            self.nodeID = nodeID
        }
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case needsRefresh
        case unavailable
        case failed(WebInspectorProxyError)
    }

    struct SetStyleTextIntent {
        let styleID: CSS.Style.ID
        let text: String
    }

    public let id: ID
    public private(set) var phase: Phase
    public private(set) var sections: [CSSStyleSection]
    public private(set) var computedProperties: [CSS.ComputedProperty]

    @ObservationIgnored weak var modelContext: WebInspectorContext?
    @ObservationIgnored private var inspectorBaselines: [CSS.Property.ID: CSSPropertyInspectorBaseline]

    init(nodeID: DOMNode.ID, modelContext: WebInspectorContext) {
        id = ID(nodeID: nodeID)
        phase = .loading
        sections = []
        computedProperties = []
        inspectorBaselines = [:]
        self.modelContext = modelContext
    }

    func markLoading() {
        phase = .loading
    }

    func load(
        matchedStyles: CSS.MatchedStyles,
        inlineStyles: CSS.InlineStyles,
        computedProperties: [CSS.ComputedProperty]
    ) {
        sections = CSSStyleSectionBuilder.makeSections(matched: matchedStyles, inline: inlineStyles)
            .map { section($0, replacingStyleWith: applyingInspectorBaselines(to: $0.style)) }
        self.computedProperties = computedProperties
        phase = .loaded
    }

    func markNeedsRefresh() {
        phase = .needsRefresh
    }

    func markUnavailable() {
        sections = []
        computedProperties = []
        inspectorBaselines = [:]
        phase = .unavailable
    }

    func fail(_ error: WebInspectorProxyError) {
        sections = []
        computedProperties = []
        inspectorBaselines = [:]
        phase = .failed(error)
    }

    /// Synchronous validation for a property toggle: returns the backend
    /// command inputs when the property is currently editable, or nil to
    /// refuse the toggle (stale phase, non-editable section/style/property,
    /// no-op toggle, or unrewritable style text).
    func setStyleTextIntent(for propertyID: CSS.Property.ID, enabled: Bool) -> SetStyleTextIntent? {
        guard phase == .loaded,
              let (sectionIndex, propertyIndex) = locateProperty(propertyID) else {
            return nil
        }
        let section = sections[sectionIndex]
        guard section.isEditable else {
            return nil
        }
        let style = section.style
        guard style.isEditable else {
            return nil
        }
        let property = style.properties[propertyIndex]
        guard property.isEditable,
              (property.status != .disabled) != enabled,
              let text = CSSStyleTextRewriter.rewrittenStyleText(
                  style: style,
                  propertyIndex: propertyIndex,
                  enabled: enabled
              ) else {
            return nil
        }
        return SetStyleTextIntent(styleID: style.id, text: text)
    }

    /// Applies a `CSS.setStyleText` result: records the toggled property's
    /// pre-edit baseline, rewrites every section sharing the returned
    /// style's ID (keeping section identity), recomputes
    /// `isModifiedByInspector` against recorded baselines, and marks the
    /// styles stale for the follow-up refresh.
    func applySetStyleText(result: CSS.Style, for propertyID: CSS.Property.ID) {
        var didRewriteSection = false
        for index in sections.indices where sections[index].style.id == result.id {
            let section = sections[index]
            if inspectorBaselines[propertyID] == nil,
               let property = section.style.properties.first(where: { $0.id == propertyID }) {
                inspectorBaselines[propertyID] = CSSPropertyInspectorBaseline(property)
            }
            let normalized = CSSStyleSectionBuilder.normalizedStyle(
                result,
                isEditable: section.isEditable,
                ruleOrigin: section.rule?.origin
            )
            sections[index] = self.section(section, replacingStyleWith: applyingInspectorBaselines(to: normalized))
            didRewriteSection = true
        }
        if didRewriteSection {
            phase = .needsRefresh
        }
    }

    private func locateProperty(_ propertyID: CSS.Property.ID) -> (sectionIndex: Int, propertyIndex: Int)? {
        for sectionIndex in sections.indices {
            guard let propertyIndex = sections[sectionIndex].style.properties.firstIndex(
                where: { $0.id == propertyID }
            ) else {
                continue
            }
            return (sectionIndex, propertyIndex)
        }
        return nil
    }

    private func section(_ section: CSSStyleSection, replacingStyleWith style: CSS.Style) -> CSSStyleSection {
        var rule = section.rule
        rule?.style = style
        return CSSStyleSection(
            id: section.id,
            kind: section.kind,
            title: section.title,
            rule: rule,
            style: style,
            isEditable: section.isEditable
        )
    }

    private func applyingInspectorBaselines(to style: CSS.Style) -> CSS.Style {
        guard inspectorBaselines.isEmpty == false else {
            return style
        }
        var style = style
        style.properties = style.properties.map { property in
            guard let baseline = inspectorBaselines[property.id] else {
                return property
            }
            let isModified = CSSPropertyInspectorBaseline(property) != baseline
            if isModified == false {
                inspectorBaselines[property.id] = nil
            }
            return CSS.Property(
                id: property.id,
                name: property.name,
                value: property.value,
                priority: property.priority,
                text: property.text,
                parsedOk: property.parsedOk,
                status: property.status,
                implicit: property.implicit,
                range: property.range,
                isEditable: property.isEditable,
                isModifiedByInspector: isModified
            )
        }
        return style
    }
}

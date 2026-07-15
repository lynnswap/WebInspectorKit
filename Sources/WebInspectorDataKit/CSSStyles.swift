import Foundation
import Observation
import WebInspectorProxyKit

/// Pre-edit snapshot of a property row, recorded the first time the
/// inspector rewrites its declaration. A property is "modified by
/// inspector" while its current state differs from this baseline.
private struct CSSPropertyInspectorBaseline: Equatable {
    var styleID: CSS.Style.ID
    var name: String
    var value: String
    var priority: String?
    var text: String?
    var status: CSS.Status

    init(styleID: CSS.Style.ID, property: CSS.Property) {
        self.styleID = styleID
        name = property.name
        value = property.value
        priority = property.priority
        text = property.text
        status = property.status
    }
}

private struct CSSInspectorBaselineName: Hashable {
    var styleID: CSS.Style.ID
    var propertyName: String
}

/// Context-owned edit history for backend style declarations. Stylesheet
/// rules are shared by every DOM node they match, so a node-owned `CSSStyles`
/// resource cannot own this state. `CSS.Style.ID` carries ProxyKit's target
/// scope; current-page entries are retired by the document lifecycle owner.
final class CSSInspectorBaselineStore {
    private var baselines: [CSSStyleProperty.ID: CSSPropertyInspectorBaseline] = [:]

    func reset() {
        baselines.removeAll()
    }

    func reset(targetID: WebInspectorTarget.ID) {
        baselines = baselines.filter { _, baseline in
            baseline.styleID.targetScopeRawValue != targetID.rawValue
        }
    }

    func recordIfNeeded(
        propertyID: CSSStyleProperty.ID,
        styleID: CSS.Style.ID,
        property: CSS.Property
    ) {
        guard baselines[propertyID] == nil else {
            return
        }
        baselines[propertyID] = CSSPropertyInspectorBaseline(
            styleID: styleID,
            property: property
        )
    }

    /// Backend property IDs are positional. An authoritative mutation result
    /// may change declaration topology, so preserve a baseline only when its
    /// name identifies exactly one old baseline and one incoming declaration.
    func reconcile(
        styleIDs: Set<CSS.Style.ID>,
        incomingSections: [CSSStyleSection]
    ) {
        guard styleIDs.isEmpty == false else {
            return
        }

        let incomingPropertiesByStyleID = cssPropertiesByStyleID(in: incomingSections)
        let baselineNameCounts = Dictionary(
            grouping: baselines.values,
            by: { baseline in
                CSSInspectorBaselineName(
                    styleID: baseline.styleID,
                    propertyName: baseline.name
                )
            }
        ).mapValues(\.count)
        var reconciled: [CSSStyleProperty.ID: CSSPropertyInspectorBaseline] = [:]

        for (propertyID, baseline) in baselines {
            guard styleIDs.contains(baseline.styleID) else {
                reconciled[propertyID] = baseline
                continue
            }
            let name = CSSInspectorBaselineName(
                styleID: baseline.styleID,
                propertyName: baseline.name
            )
            guard baselineNameCounts[name] == 1,
                  let incomingProperties = incomingPropertiesByStyleID[baseline.styleID] else {
                continue
            }
            let matchingProperties = incomingProperties.filter { $0.name == baseline.name }
            guard matchingProperties.count == 1,
                  let incomingProperty = matchingProperties.first else {
                continue
            }
            reconciled[incomingProperty.id] = baseline
        }
        baselines = reconciled
    }

    func applyingBaselines(
        to style: CSS.Style,
        clearsRestoredBaselines: Bool = false
    ) -> CSS.Style {
        guard baselines.isEmpty == false else {
            return style
        }
        var style = style
        style.properties = style.properties.map { property in
            let propertyID = CSSStyleProperty.ID(property.id)
            guard let baseline = baselines[propertyID],
                  baseline.styleID == style.id,
                  baseline.name == property.name else {
                return property
            }
            let isModified = CSSPropertyInspectorBaseline(
                styleID: style.id,
                property: property
            ) != baseline
            if isModified == false, clearsRestoredBaselines {
                baselines[propertyID] = nil
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

private func cssPropertiesByStyleID(
    in sections: [CSSStyleSection]
) -> [CSS.Style.ID: [CSSStyleProperty]] {
    var result: [CSS.Style.ID: [CSSStyleProperty]] = [:]
    for section in sections {
        let styleID = section.proxyStyle.id
        if let existing = result[styleID] {
            precondition(
                existing.map(\.name) == section.style.properties.map(\.name),
                "Sections sharing a CSS style must agree on declaration topology."
            )
        } else {
            result[styleID] = section.style.properties
        }
    }
    return result
}

/// Observable CSS state for one DOM element.
@Observable
public final class CSSStyles: WebInspectorPersistentModel {
    /// Stable identity for an element's CSS style model.
    public struct ID: Hashable, Sendable {
        let nodeID: DOMNode.ID

        init(nodeID: DOMNode.ID) {
            self.nodeID = nodeID
        }
    }

    /// Loading phase for element style data.
    public enum Phase: Equatable, Sendable {
        /// CSS information is currently being requested.
        case loading

        /// CSS information has been loaded.
        case loaded

        /// CSS information is stale and should be refreshed.
        case needsRefresh

        /// CSS information is unavailable for the element.
        case unavailable

        /// CSS information failed to load.
        case failed(WebInspectorProxyError)
    }

    struct SetStyleTextIntent {
        let styleID: CSS.Style.ID
        let text: String
    }

    /// The stable style model identity.
    public let id: ID

    /// The current loading phase.
    public private(set) var phase: Phase

    /// Style sections displayed for the element.
    public private(set) var sections: [CSSStyleSection]

    /// Computed properties for the element.
    public private(set) var computedProperties: [CSSComputedProperty]

    @ObservationIgnored weak var modelContext: WebInspectorContext?
    @ObservationIgnored private let inspectorBaselineStore: CSSInspectorBaselineStore

    init(nodeID: DOMNode.ID, modelContext: WebInspectorContext) {
        id = ID(nodeID: nodeID)
        phase = .loading
        sections = []
        computedProperties = []
        inspectorBaselineStore = modelContext.cssInspectorBaselineStore
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
            .map {
                section(
                    $0,
                    replacingStyleWith: inspectorBaselineStore.applyingBaselines(to: $0.proxyStyle)
                )
            }
        self.computedProperties = computedProperties.map(CSSComputedProperty.init)
        phase = .loaded
    }

    func markNeedsRefresh() {
        phase = .needsRefresh
    }

    func markUnavailable() {
        sections = []
        computedProperties = []
        phase = .unavailable
    }

    func fail(_ error: WebInspectorProxyError) {
        sections = []
        computedProperties = []
        phase = .failed(error)
    }

    /// Synchronous validation for a property toggle: returns the backend
    /// command inputs when the property is currently editable, or nil to
    /// refuse the toggle (stale phase, non-editable section/style/property,
    /// no-op toggle, or unrewritable style text).
    func setStyleTextIntent(for propertyID: CSSStyleProperty.ID, enabled: Bool) -> SetStyleTextIntent? {
        guard phase == .loaded,
              let (sectionIndex, propertyIndex) = locateProperty(propertyID) else {
            return nil
        }
        let section = sections[sectionIndex]
        guard section.isEditable else {
            return nil
        }
        let style = section.proxyStyle
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

    func setDeclarationTextIntent(for propertyID: CSSStyleProperty.ID, text replacementText: String) -> SetStyleTextIntent? {
        guard phase == .loaded,
              let (sectionIndex, propertyIndex) = locateProperty(propertyID) else {
            return nil
        }
        let section = sections[sectionIndex]
        guard section.isEditable else {
            return nil
        }
        let style = section.proxyStyle
        guard style.isEditable else {
            return nil
        }
        let property = style.properties[propertyIndex]
        guard property.isEditable,
              let text = CSSStyleTextRewriter.rewrittenStyleText(
                  style: style,
                  propertyIndex: propertyIndex,
                  replacementText: replacementText
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
    func applySetStyleText(result: CSS.Style, for propertyID: CSSStyleProperty.ID) {
        var updatedSections = sections
        var didRewriteSection = false
        for index in sections.indices where sections[index].proxyStyle.id == result.id {
            let section = sections[index]
            if let property = section.proxyStyle.properties.first(where: { $0.id == propertyID.proxyID }) {
                inspectorBaselineStore.recordIfNeeded(
                    propertyID: propertyID,
                    styleID: section.proxyStyle.id,
                    property: property
                )
            }
            let normalized = CSSStyleSectionBuilder.normalizedStyle(
                result,
                isEditable: section.isEditable,
                ruleOrigin: section.proxyRule?.origin
            )
            updatedSections[index] = self.section(section, replacingStyleWith: normalized)
            didRewriteSection = true
        }
        if didRewriteSection {
            inspectorBaselineStore.reconcile(
                styleIDs: styleIDsWithChangedPropertyTopology(in: updatedSections),
                incomingSections: updatedSections
            )
            sections = updatedSections.map {
                section(
                    $0,
                    replacingStyleWith: inspectorBaselineStore.applyingBaselines(
                        to: $0.proxyStyle,
                        clearsRestoredBaselines: true
                    )
                )
            }
            phase = .needsRefresh
        }
    }

    private func locateProperty(_ propertyID: CSSStyleProperty.ID) -> (sectionIndex: Int, propertyIndex: Int)? {
        for sectionIndex in sections.indices {
            guard let propertyIndex = sections[sectionIndex].proxyStyle.properties.firstIndex(
                where: { $0.id == propertyID.proxyID }
            ) else {
                continue
            }
            return (sectionIndex, propertyIndex)
        }
        return nil
    }

    private func section(_ section: CSSStyleSection, replacingStyleWith style: CSS.Style) -> CSSStyleSection {
        var rule = section.proxyRule
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

    private func styleIDsWithChangedPropertyTopology(
        in incomingSections: [CSSStyleSection]
    ) -> Set<CSS.Style.ID> {
        let existingPropertiesByStyleID = cssPropertiesByStyleID(in: sections)
        let incomingPropertiesByStyleID = cssPropertiesByStyleID(in: incomingSections)
        let allStyleIDs = Set(existingPropertiesByStyleID.keys)
            .union(incomingPropertiesByStyleID.keys)
        return Set(allStyleIDs.filter { styleID in
            existingPropertiesByStyleID[styleID]?.map(\.name)
                != incomingPropertiesByStyleID[styleID]?.map(\.name)
        })
    }
}

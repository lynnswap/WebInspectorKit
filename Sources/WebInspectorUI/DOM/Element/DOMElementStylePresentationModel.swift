#if canImport(UIKit)
import WebInspectorCore
import Observation
import UIKit

@MainActor
package struct DOMElementStylePresentationItemIdentifier: Hashable {
    package enum Kind: Hashable {
        case property(propertyID: CSSProperty.ID?, propertyIndex: Int)
        case hiddenUnusedVariables(count: Int)
    }

    package var sectionID: CSSStyle.Section.ID
    package var kind: Kind
}

@MainActor
package struct DOMElementStylePresentationSection {
    package var id: CSSStyle.Section.ID
    package var items: [DOMElementStylePresentationItemIdentifier]
}

@MainActor
package struct DOMElementStylePresentationRender {
    package var snapshot: NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    >
    package var reconfiguredItemIdentifiers: [DOMElementStylePresentationItemIdentifier]
}

@MainActor
package enum DOMElementStyleDiffableSnapshotBuilder {
    package static func visibleSections(
        sections: [CSSStyle.Section],
        expandedUnusedVariableSectionIDs: Set<CSSStyle.Section.ID>
    ) -> [DOMElementStylePresentationSection] {
        var visibleSections: [DOMElementStylePresentationSection] = []
        let usedCSSVariables = DOMElementStyleVariableVisibility.usedCSSVariableNames(in: sections)

        for section in sections where !section.style.cssProperties.isEmpty {
            let hiddenVariableIndices = DOMElementStyleVariableVisibility.hiddenUnusedVariableIndices(
                in: section,
                usedCSSVariables: usedCSSVariables
            )
            let showsHiddenVariables = expandedUnusedVariableSectionIDs.contains(section.id)
            let propertyItems = section.style.cssProperties.enumerated().compactMap {
                index,
                property -> DOMElementStylePresentationItemIdentifier? in
                guard showsHiddenVariables || !hiddenVariableIndices.contains(index) else {
                    return nil
                }
                return DOMElementStylePresentationItemIdentifier(
                    sectionID: section.id,
                    kind: .property(propertyID: property.id, propertyIndex: index)
                )
            }
            guard !propertyItems.isEmpty || !hiddenVariableIndices.isEmpty else {
                continue
            }

            var items = propertyItems
            if !hiddenVariableIndices.isEmpty && !showsHiddenVariables {
                items.append(
                    DOMElementStylePresentationItemIdentifier(
                        sectionID: section.id,
                        kind: .hiddenUnusedVariables(count: hiddenVariableIndices.count)
                    )
                )
            }
            visibleSections.append(
                DOMElementStylePresentationSection(
                    id: section.id,
                    items: items
                )
            )
        }

        return visibleSections
    }

    package static func makeSnapshot(
        visibleSections: [DOMElementStylePresentationSection]
    ) -> NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        var snapshot = NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >()
        for section in visibleSections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.items, toSection: section.id)
        }
        return snapshot
    }
}

@MainActor
@Observable
package final class DOMElementStylePresentationState {
    package enum RenderResult {
        case loaded(DOMElementStylePresentationRender)
        case pending
        case unavailable
    }

    private struct ItemFingerprint: Equatable {
        var propertyObjectID: ObjectIdentifier
        var propertyID: CSSProperty.ID?
        var name: String
        var value: String
        var priority: String
        var text: String?
        var status: CSSProperty.Status
        var isEditable: Bool
        var isModifiedByInspector: Bool

        init(property: CSSProperty) {
            propertyObjectID = ObjectIdentifier(property)
            propertyID = property.id
            name = property.name
            value = property.value
            priority = property.priority
            text = property.text
            status = property.status
            isEditable = property.isEditable
            isModifiedByInspector = property.isModifiedByInspector
        }
    }

    @ObservationIgnored private var expandedUnusedVariableSectionIDs = Set<CSSStyle.Section.ID>()
    @ObservationIgnored private var displayedNodeStyles: CSSNodeStyles?
    @ObservationIgnored private var visibleSections: [DOMElementStylePresentationSection] = []
    @ObservationIgnored private var displayedItemFingerprints: [DOMElementStylePresentationItemIdentifier: ItemFingerprint] = [:]

    package init() {}

    package var visibleSectionIDs: [CSSStyle.Section.ID] {
        visibleSections.map(\.id)
    }

    package var displayedNodeStylesID: CSSNodeStyles.ID? {
        displayedNodeStyles?.id
    }

    package func render(_ nodeStyles: CSSNodeStyles) -> RenderResult {
        switch nodeStyles.phase {
        case .loaded:
            displayedNodeStyles = nodeStyles
            rebuildVisibleSections()
            return .loaded(renderSnapshot())
        case .loading, .needsRefresh:
            return renderPending()
        case .unavailable, .failed:
            return renderUnavailable()
        }
    }

    package func render(_ phase: CSSNodeStyles.Phase) -> RenderResult {
        switch phase {
        case .loaded:
            if displayedNodeStyles != nil {
                rebuildVisibleSections()
                return .loaded(renderSnapshot())
            }
            return renderUnavailable()
        case .loading, .needsRefresh:
            return renderPending()
        case .unavailable, .failed:
            return renderUnavailable()
        }
    }

    package func showHiddenUnusedVariables(
        in sectionID: CSSStyle.Section.ID
    ) -> DOMElementStylePresentationRender? {
        guard let displayedNodeStyles else {
            return nil
        }
        let currentSectionIDs = Set(displayedNodeStyles.sections.map(\.id))
        expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)
        guard currentSectionIDs.contains(sectionID) else {
            return nil
        }
        expandedUnusedVariableSectionIDs.insert(sectionID)
        rebuildVisibleSections()
        return renderSnapshot()
    }

    package func section(for sectionID: CSSStyle.Section.ID) -> CSSStyle.Section? {
        displayedNodeStyles?.sections.first { $0.id == sectionID }
    }

    package func property(
        for item: DOMElementStylePresentationItemIdentifier,
        in section: CSSStyle.Section
    ) -> CSSProperty? {
        guard case let .property(propertyID, propertyIndex) = item.kind else {
            return nil
        }
        if let propertyID {
            return section.style.cssProperties.first { $0.id == propertyID }
        }
        guard section.style.cssProperties.indices.contains(propertyIndex) else {
            return nil
        }
        return section.style.cssProperties[propertyIndex]
    }

    private func renderPending() -> RenderResult {
        guard displayedNodeStyles != nil else {
            return renderUnavailable()
        }
        return .pending
    }

    private func renderUnavailable() -> RenderResult {
        expandedUnusedVariableSectionIDs.removeAll()
        displayedNodeStyles = nil
        visibleSections = []
        displayedItemFingerprints.removeAll()
        return .unavailable
    }

    private func rebuildVisibleSections() {
        guard let displayedNodeStyles else {
            visibleSections = []
            return
        }
        let currentSectionIDs = Set(displayedNodeStyles.sections.map(\.id))
        expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)
        visibleSections = DOMElementStyleDiffableSnapshotBuilder.visibleSections(
            sections: displayedNodeStyles.sections,
            expandedUnusedVariableSectionIDs: expandedUnusedVariableSectionIDs
        )
    }

    private func diffableSnapshot() -> NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        DOMElementStyleDiffableSnapshotBuilder.makeSnapshot(
            visibleSections: visibleSections
        )
    }

    private func renderSnapshot() -> DOMElementStylePresentationRender {
        let snapshot = diffableSnapshot()
        let fingerprints = visibleItemFingerprints()
        let reconfiguredItemIdentifiers = snapshot.itemIdentifiers.filter { item in
            guard let fingerprint = fingerprints[item] else {
                return false
            }
            return displayedItemFingerprints[item] != fingerprint
        }
        displayedItemFingerprints = fingerprints
        return DOMElementStylePresentationRender(
            snapshot: snapshot,
            reconfiguredItemIdentifiers: reconfiguredItemIdentifiers
        )
    }

    private func visibleItemFingerprints() -> [DOMElementStylePresentationItemIdentifier: ItemFingerprint] {
        guard let displayedNodeStyles else {
            return [:]
        }
        let sectionsByID = Dictionary(uniqueKeysWithValues: displayedNodeStyles.sections.map { ($0.id, $0) })
        var fingerprints: [DOMElementStylePresentationItemIdentifier: ItemFingerprint] = [:]
        for visibleSection in visibleSections {
            guard let section = sectionsByID[visibleSection.id] else {
                continue
            }
            for item in visibleSection.items {
                guard let property = property(for: item, in: section) else {
                    continue
                }
                fingerprints[item] = ItemFingerprint(property: property)
            }
        }
        return fingerprints
    }
}
#endif

#if canImport(UIKit)
import WebInspectorCore
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
package struct DOMElementStylePresentationSnapshot {
    package struct Section {
        package var source: CSSStyle.Section
        package var items: [DOMElementStylePresentationItemIdentifier]
    }

    fileprivate var sourceSections: [CSSStyle.Section]
    private var visibleSections: [Section]

    package init(
        sourceSections: [CSSStyle.Section],
        visibleSections: [Section]
    ) {
        self.sourceSections = sourceSections
        self.visibleSections = visibleSections
    }

    package func diffableSnapshot() -> NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        var snapshot = NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >()
        for section in visibleSections {
            snapshot.appendSections([section.source.id])
            snapshot.appendItems(section.items, toSection: section.source.id)
        }
        return snapshot
    }

    package func section(for sectionID: CSSStyle.Section.ID) -> CSSStyle.Section? {
        sourceSections.first { $0.id == sectionID }
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
}

@MainActor
package struct DOMElementStyleSnapshotBuilder {
    package static func makeSnapshot(
        sections: [CSSStyle.Section],
        expandedUnusedVariableSectionIDs: Set<CSSStyle.Section.ID>
    ) -> DOMElementStylePresentationSnapshot {
        var visibleSections: [DOMElementStylePresentationSnapshot.Section] = []
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
                DOMElementStylePresentationSnapshot.Section(
                    source: section,
                    items: items
                )
            )
        }

        return DOMElementStylePresentationSnapshot(
            sourceSections: sections,
            visibleSections: visibleSections
        )
    }
}

@MainActor
package struct DOMElementStylePresentationModel {
    package enum RenderResult {
        case loaded(DOMElementStylePresentationSnapshot)
        case pending
        case unavailable
    }

    private var expandedUnusedVariableSectionIDs = Set<CSSStyle.Section.ID>()
    private var displayedSnapshot: DOMElementStylePresentationSnapshot?

    package var snapshot: DOMElementStylePresentationSnapshot? {
        displayedSnapshot
    }

    package mutating func render(_ nodeStyles: CSSNodeStyles) -> RenderResult {
        switch nodeStyles.phase {
        case .loaded:
            let currentSectionIDs = Set(nodeStyles.sections.map(\.id))
            expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)
            let snapshot = DOMElementStyleSnapshotBuilder.makeSnapshot(
                sections: nodeStyles.sections,
                expandedUnusedVariableSectionIDs: expandedUnusedVariableSectionIDs
            )
            displayedSnapshot = snapshot
            return .loaded(snapshot)
        case .loading, .needsRefresh:
            return renderPending()
        case .unavailable, .failed:
            return renderUnavailable()
        }
    }

    package mutating func render(_ phase: CSSNodeStyles.Phase) -> RenderResult {
        switch phase {
        case .loaded:
            if let displayedSnapshot {
                return .loaded(displayedSnapshot)
            }
            return renderUnavailable()
        case .loading, .needsRefresh:
            return renderPending()
        case .unavailable, .failed:
            return renderUnavailable()
        }
    }

    package mutating func showHiddenUnusedVariables(
        in sectionID: CSSStyle.Section.ID
    ) -> DOMElementStylePresentationSnapshot? {
        guard let displayedSnapshot else {
            return nil
        }
        expandedUnusedVariableSectionIDs.insert(sectionID)
        let snapshot = DOMElementStyleSnapshotBuilder.makeSnapshot(
            sections: displayedSnapshot.sourceSections,
            expandedUnusedVariableSectionIDs: expandedUnusedVariableSectionIDs
        )
        self.displayedSnapshot = snapshot
        return snapshot
    }

    private mutating func renderPending() -> RenderResult {
        guard displayedSnapshot != nil else {
            return renderUnavailable()
        }
        return .pending
    }

    private mutating func renderUnavailable() -> RenderResult {
        expandedUnusedVariableSectionIDs.removeAll()
        displayedSnapshot = nil
        return .unavailable
    }
}
#endif

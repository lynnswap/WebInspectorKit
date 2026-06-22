#if canImport(UIKit)
import WebInspectorUIBase
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
package struct DOMElementStylePresentationSection {
    package var id: CSSStyle.Section.ID
    package var items: [DOMElementStylePresentationItemIdentifier]
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
package final class DOMElementStyleSnapshotCoordinator {
    package typealias Snapshot = NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    >

    package enum ApplyMode: Equatable {
        case none
        case diff(animated: Bool)
        case reloadData
    }

    package enum PlaceholderMode: Equatable {
        case none
        case unavailable
    }

    package struct SnapshotUpdate {
        package var snapshot: Snapshot?
        package var applyMode: ApplyMode
        package var placeholderMode: PlaceholderMode
    }

    private struct SelectionEpoch {
        var objectID: ObjectIdentifier
        var hasRenderedLoadedSnapshot = false
    }

    private struct VisibleBindingTopology: Equatable {
        var sectionObjectIDs: [CSSStyle.Section.ID: ObjectIdentifier]
        var propertyObjectIDs: [DOMElementStylePresentationItemIdentifier: ObjectIdentifier]

        static let empty = VisibleBindingTopology(
            sectionObjectIDs: [:],
            propertyObjectIDs: [:]
        )
    }

    private var expandedUnusedVariableSectionIDs = Set<CSSStyle.Section.ID>()
    private var displayedNodeStyles: CSSNodeStyles?
    private var visibleSections: [DOMElementStylePresentationSection] = []
    private var visibleBindingTopology = VisibleBindingTopology.empty
    private var selectionEpoch: SelectionEpoch?

    package init() {}

    package var visibleSectionIDs: [CSSStyle.Section.ID] {
        visibleSections.map(\.id)
    }

    package func bindSelectedNodeStyles(_ nodeStyles: CSSNodeStyles) {
        let objectID = ObjectIdentifier(nodeStyles)
        guard selectionEpoch?.objectID != objectID else {
            return
        }
        selectionEpoch = SelectionEpoch(objectID: objectID)
    }

    package func updateSelectedNodeStyles(_ nodeStyles: CSSNodeStyles) -> SnapshotUpdate {
        bindSelectedNodeStyles(nodeStyles)
        switch nodeStyles.phase {
        case .loaded:
            return updateLoadedSnapshot(nodeStyles)
        case .loading, .needsRefresh:
            return updatePendingSnapshot()
        case .unavailable, .failed:
            return updateUnavailableSnapshot()
        }
    }

    package func updateUnavailablePhase(_ phase: CSSNodeStyles.Phase) -> SnapshotUpdate {
        selectionEpoch = nil
        switch phase {
        case .loaded:
            return updateUnavailableSnapshot()
        case .loading, .needsRefresh:
            return updatePendingSnapshot()
        case .unavailable, .failed:
            return updateUnavailableSnapshot()
        }
    }

    package func revealHiddenUnusedVariables(
        in sectionID: CSSStyle.Section.ID
    ) -> SnapshotUpdate? {
        guard let displayedNodeStyles else {
            return nil
        }
        let oldSectionIDs = visibleSectionIDs
        let oldItemIDs = visibleItemIDs
        let currentSectionIDs = Set(displayedNodeStyles.sections.map(\.id))
        expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)
        guard currentSectionIDs.contains(sectionID) else {
            return nil
        }
        expandedUnusedVariableSectionIDs.insert(sectionID)
        rebuildVisibleSections()
        let snapshot = diffableSnapshot()
        visibleBindingTopology = makeVisibleBindingTopology()
        guard Self.hasStructuralChanges(
            oldSectionIDs: oldSectionIDs,
            oldItemIDs: oldItemIDs,
            snapshot: snapshot
        ) else {
            return SnapshotUpdate(snapshot: nil, applyMode: .none, placeholderMode: .none)
        }
        return SnapshotUpdate(snapshot: snapshot, applyMode: .diff(animated: true), placeholderMode: .none)
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

    private var visibleItemIDs: [DOMElementStylePresentationItemIdentifier] {
        visibleSections.flatMap(\.items)
    }

    private func updateLoadedSnapshot(_ nodeStyles: CSSNodeStyles) -> SnapshotUpdate {
        let oldSectionIDs = visibleSectionIDs
        let oldItemIDs = visibleItemIDs
        let oldBindingTopology = visibleBindingTopology
        let replacesSelection = selectionEpoch?.hasRenderedLoadedSnapshot == false
        let hadVisibleSnapshot = visibleSections.isEmpty == false

        displayedNodeStyles = nodeStyles
        rebuildVisibleSections()

        let snapshot = diffableSnapshot()
        let newBindingTopology = makeVisibleBindingTopology()
        let hasStructuralChanges = Self.hasStructuralChanges(
            oldSectionIDs: oldSectionIDs,
            oldItemIDs: oldItemIDs,
            snapshot: snapshot
        )
        let hasBindingChanges = oldBindingTopology != newBindingTopology

        let applyMode: ApplyMode
        if replacesSelection {
            applyMode = hadVisibleSnapshot ? .reloadData : .diff(animated: false)
        } else if hasStructuralChanges {
            applyMode = .diff(animated: true)
        } else if hasBindingChanges {
            applyMode = .reloadData
        } else {
            selectionEpoch?.hasRenderedLoadedSnapshot = true
            visibleBindingTopology = newBindingTopology
            return SnapshotUpdate(snapshot: nil, applyMode: .none, placeholderMode: .none)
        }
        selectionEpoch?.hasRenderedLoadedSnapshot = true
        visibleBindingTopology = newBindingTopology
        return SnapshotUpdate(snapshot: snapshot, applyMode: applyMode, placeholderMode: .none)
    }

    private func updatePendingSnapshot() -> SnapshotUpdate {
        guard displayedNodeStyles != nil else {
            return updateUnavailableSnapshot()
        }
        return SnapshotUpdate(snapshot: nil, applyMode: .none, placeholderMode: .none)
    }

    private func updateUnavailableSnapshot() -> SnapshotUpdate {
        let oldSectionIDs = visibleSectionIDs
        let oldItemIDs = visibleItemIDs
        expandedUnusedVariableSectionIDs.removeAll()
        displayedNodeStyles = nil
        visibleSections = []
        visibleBindingTopology = .empty
        let snapshot = diffableSnapshot()
        let applyMode: ApplyMode = Self.hasStructuralChanges(
            oldSectionIDs: oldSectionIDs,
            oldItemIDs: oldItemIDs,
            snapshot: snapshot
        ) ? .diff(animated: false) : .none
        return SnapshotUpdate(snapshot: snapshot, applyMode: applyMode, placeholderMode: .unavailable)
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

    private func makeVisibleBindingTopology() -> VisibleBindingTopology {
        guard let displayedNodeStyles else {
            return .empty
        }

        let sectionsByID = Dictionary(uniqueKeysWithValues: displayedNodeStyles.sections.map { ($0.id, $0) })
        var sectionObjectIDs: [CSSStyle.Section.ID: ObjectIdentifier] = [:]
        var propertyObjectIDs: [DOMElementStylePresentationItemIdentifier: ObjectIdentifier] = [:]

        for visibleSection in visibleSections {
            guard let section = sectionsByID[visibleSection.id] else {
                continue
            }
            sectionObjectIDs[visibleSection.id] = ObjectIdentifier(section)
            for item in visibleSection.items {
                guard let property = property(for: item, in: section) else {
                    continue
                }
                propertyObjectIDs[item] = ObjectIdentifier(property)
            }
        }

        return VisibleBindingTopology(
            sectionObjectIDs: sectionObjectIDs,
            propertyObjectIDs: propertyObjectIDs
        )
    }

    private static func hasStructuralChanges(
        oldSectionIDs: [CSSStyle.Section.ID],
        oldItemIDs: [DOMElementStylePresentationItemIdentifier],
        snapshot: Snapshot
    ) -> Bool {
        oldSectionIDs != snapshot.sectionIdentifiers
            || oldItemIDs != snapshot.itemIdentifiers
    }
}
#endif

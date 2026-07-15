#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
package struct DOMElementStylePresentationItemIdentifier: Hashable {
    package enum Kind: Hashable {
        case property(propertyID: CSSStyleProperty.ID, propertyIndex: Int)
        case hiddenUnusedVariables(count: Int)
    }

    package var sectionID: CSSStyleSection.ID
    package var kind: Kind
}

@MainActor
package struct DOMElementStylePresentationSection {
    package var id: CSSStyleSection.ID
    package var items: [DOMElementStylePresentationItemIdentifier]
}

@MainActor
package enum DOMElementStyleDiffableSnapshotBuilder {
    package static func visibleSections(
        sections: [CSSStyleSection],
        expandedUnusedVariableSectionIDs: Set<CSSStyleSection.ID>
    ) -> [DOMElementStylePresentationSection] {
        var visibleSections: [DOMElementStylePresentationSection] = []
        let usedCSSVariables = DOMElementStyleVariableVisibility.usedCSSVariableNames(in: sections)

        for section in sections where !section.style.properties.isEmpty {
            let hiddenVariableIndices = DOMElementStyleVariableVisibility.hiddenUnusedVariableIndices(
                in: section,
                usedCSSVariables: usedCSSVariables
            )
            let showsHiddenVariables = expandedUnusedVariableSectionIDs.contains(section.id)
            let propertyItems = section.style.properties.enumerated().compactMap {
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
        CSSStyleSection.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        var snapshot = NSDiffableDataSourceSnapshot<
            CSSStyleSection.ID,
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
        CSSStyleSection.ID,
        DOMElementStylePresentationItemIdentifier
    >

    package enum ApplyMode: Equatable {
        case none
        case diff(animated: Bool)
    }

    package enum PlaceholderMode: Equatable {
        case none
        case unavailable
    }

    package struct SnapshotUpdate {
        package enum Application {
            case none
            case diff(snapshot: Snapshot, animated: Bool)
        }

        package var application: Application
        package var placeholderMode: PlaceholderMode
        /// The selected CSS resource changed while its diffable identifiers
        /// remained equal. Visible cells must bind the replacement property
        /// identities without reloading collection topology.
        package var rebindVisiblePropertyRows: Bool
        /// Sections whose rendered header content changed while keeping
        /// their identity; visible header views must be re-bound because
        /// diffable snapshots do not reconfigure supplementary views.
        package var updatedSectionIDs: Set<CSSStyleSection.ID>

        private init(
            application: Application,
            placeholderMode: PlaceholderMode,
            rebindVisiblePropertyRows: Bool = false,
            updatedSectionIDs: Set<CSSStyleSection.ID> = []
        ) {
            self.application = application
            self.placeholderMode = placeholderMode
            self.rebindVisiblePropertyRows = rebindVisiblePropertyRows
            self.updatedSectionIDs = updatedSectionIDs
        }

        package static func none(
            placeholderMode: PlaceholderMode,
            rebindVisiblePropertyRows: Bool = false,
            updatedSectionIDs: Set<CSSStyleSection.ID> = []
        ) -> SnapshotUpdate {
            SnapshotUpdate(
                application: .none,
                placeholderMode: placeholderMode,
                rebindVisiblePropertyRows: rebindVisiblePropertyRows,
                updatedSectionIDs: updatedSectionIDs
            )
        }

        package static func diff(
            snapshot: Snapshot,
            animated: Bool,
            placeholderMode: PlaceholderMode,
            rebindVisiblePropertyRows: Bool = false,
            updatedSectionIDs: Set<CSSStyleSection.ID> = []
        ) -> SnapshotUpdate {
            SnapshotUpdate(
                application: .diff(snapshot: snapshot, animated: animated),
                placeholderMode: placeholderMode,
                rebindVisiblePropertyRows: rebindVisiblePropertyRows,
                updatedSectionIDs: updatedSectionIDs
            )
        }

        package var snapshot: Snapshot? {
            guard case let .diff(snapshot, _) = application else { return nil }
            return snapshot
        }

        package var applyMode: ApplyMode {
            switch application {
            case .none:
                .none
            case let .diff(_, animated):
                .diff(animated: animated)
            }
        }
    }

    private struct SelectionEpoch {
        var stylesObjectID: ObjectIdentifier
        var hasRenderedLoadedSnapshot = false
    }

    /// The fields a section header renders.
    private struct SectionRenderContent: Equatable {
        var title: String?
        var originText: String?
        var accessibilityOriginText: String?

        init(_ section: CSSStyleSection) {
            title = section.title
            originText = section.rule.flatMap(DOMElementStyleSectionHeaderText.displayOriginText(for:))
            accessibilityOriginText = section.rule.flatMap(
                DOMElementStyleSectionHeaderText.accessibilityOriginText(for:)
            )
        }
    }

    /// Immutable property content rendered by a visible row. Diffable item
    /// identity remains stable while DataKit replaces a property's value.
    private struct PropertyRenderContent: Equatable {
        var id: CSSStyleProperty.ID
        var name: String
        var value: String
        var priority: String?
        var text: String?
        var parsedOk: Bool
        var status: CSSStyleProperty.Status
        var implicit: Bool
        var range: CSSStyle.SourceRange?
        var isEditable: Bool
        var isModifiedByInspector: Bool

        init(_ property: CSSStyleProperty) {
            id = property.id
            name = property.name
            value = property.value
            priority = property.priority
            text = property.text
            parsedOk = property.parsedOk
            status = property.status
            implicit = property.implicit
            range = property.range
            isEditable = property.isEditable
            isModifiedByInspector = property.isModifiedByInspector
        }
    }

    private struct VisibleRenderContent: Equatable {
        var sectionContents: [CSSStyleSection.ID: SectionRenderContent]
        var propertyContents: [DOMElementStylePresentationItemIdentifier: PropertyRenderContent]

        static let empty = VisibleRenderContent(
            sectionContents: [:],
            propertyContents: [:]
        )
    }

    private var expandedUnusedVariableSectionIDs = Set<CSSStyleSection.ID>()
    private var displayedSections: [CSSStyleSection]?
    private var visibleSections: [DOMElementStylePresentationSection] = []
    private var visibleRenderContent = VisibleRenderContent.empty
    private var selectionEpoch: SelectionEpoch?

    package init() {}

    package var visibleSectionIDs: [CSSStyleSection.ID] {
        visibleSections.map(\.id)
    }

    package func bindSelectedNodeStyles(_ styles: CSSStyles) {
        let stylesObjectID = ObjectIdentifier(styles)
        guard selectionEpoch?.stylesObjectID != stylesObjectID else {
            return
        }
        selectionEpoch = SelectionEpoch(stylesObjectID: stylesObjectID)
    }

    package func updateSelectedNodeStyles(_ styles: CSSStyles) -> SnapshotUpdate {
        bindSelectedNodeStyles(styles)
        switch styles.phase {
        case .loaded:
            return updateLoadedSnapshot(styles.sections)
        case .loading, .needsRefresh:
            return updatePendingSnapshot(styles.sections)
        case .unavailable, .failed:
            return updateUnavailableSnapshot()
        }
    }

    /// No selected element styles exist (no selection, or the selection is
    /// not an element node).
    package func updateUnavailable() -> SnapshotUpdate {
        selectionEpoch = nil
        return updateUnavailableSnapshot()
    }

    package func revealHiddenUnusedVariables(
        in sectionID: CSSStyleSection.ID
    ) -> SnapshotUpdate? {
        guard let displayedSections else {
            return nil
        }
        let oldSectionIDs = visibleSectionIDs
        let oldItemIDs = visibleItemIDs
        let currentSectionIDs = Set(displayedSections.map(\.id))
        expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)
        guard currentSectionIDs.contains(sectionID) else {
            return nil
        }
        expandedUnusedVariableSectionIDs.insert(sectionID)
        rebuildVisibleSections()
        let snapshot = diffableSnapshot()
        visibleRenderContent = makeVisibleRenderContent()
        guard Self.hasStructuralChanges(
            oldSectionIDs: oldSectionIDs,
            oldItemIDs: oldItemIDs,
            snapshot: snapshot
        ) else {
            return .none(placeholderMode: .none)
        }
        return .diff(snapshot: snapshot, animated: true, placeholderMode: .none)
    }

    package func section(for sectionID: CSSStyleSection.ID) -> CSSStyleSection? {
        displayedSections?.first { $0.id == sectionID }
    }

    package func property(
        for item: DOMElementStylePresentationItemIdentifier,
        in section: CSSStyleSection
    ) -> CSSStyleProperty? {
        guard case let .property(propertyID, _) = item.kind else {
            return nil
        }
        return section.style.properties.first { $0.id == propertyID }
    }

    private var visibleItemIDs: [DOMElementStylePresentationItemIdentifier] {
        visibleSections.flatMap(\.items)
    }

    private func updateLoadedSnapshot(_ sections: [CSSStyleSection]) -> SnapshotUpdate {
        let oldSectionIDs = visibleSectionIDs
        let oldItemIDs = visibleItemIDs
        let oldRenderContent = visibleRenderContent
        let replacesSelection = selectionEpoch?.hasRenderedLoadedSnapshot == false

        displayedSections = sections
        rebuildVisibleSections()

        let snapshot = diffableSnapshot()
        let newRenderContent = makeVisibleRenderContent()
        let hasStructuralChanges = Self.hasStructuralChanges(
            oldSectionIDs: oldSectionIDs,
            oldItemIDs: oldItemIDs,
            snapshot: snapshot
        )
        let updatedSectionIDs = Self.updatedKeys(
            old: oldRenderContent.sectionContents,
            new: newRenderContent.sectionContents
        )
        let updatedPropertyIDs = Self.updatedKeys(
            old: oldRenderContent.propertyContents,
            new: newRenderContent.propertyContents
        )

        selectionEpoch?.hasRenderedLoadedSnapshot = true
        visibleRenderContent = newRenderContent

        if replacesSelection {
            if hasStructuralChanges {
                return .diff(
                    snapshot: snapshot,
                    animated: false,
                    placeholderMode: .none,
                    rebindVisiblePropertyRows: true,
                    updatedSectionIDs: updatedSectionIDs
                )
            }
            return .none(
                placeholderMode: .none,
                rebindVisiblePropertyRows: true,
                updatedSectionIDs: updatedSectionIDs
            )
        }
        if hasStructuralChanges {
            return .diff(
                snapshot: snapshot,
                animated: true,
                placeholderMode: .none,
                rebindVisiblePropertyRows: updatedPropertyIDs.isEmpty == false,
                updatedSectionIDs: updatedSectionIDs
            )
        }
        if updatedSectionIDs.isEmpty == false || updatedPropertyIDs.isEmpty == false {
            return .none(
                placeholderMode: .none,
                rebindVisiblePropertyRows: updatedPropertyIDs.isEmpty == false,
                updatedSectionIDs: updatedSectionIDs
            )
        }
        return .none(placeholderMode: .none)
    }

    /// Pending phases (`loading`/`needsRefresh`) keep the displayed row
    /// structure frozen until the follow-up refresh lands. Same-identity
    /// property content is rendered by each row's Observation binding and
    /// never becomes a collection snapshot operation.
    private func updatePendingSnapshot(_ sections: [CSSStyleSection]) -> SnapshotUpdate {
        guard displayedSections != nil else {
            return updateUnavailableSnapshot()
        }
        guard selectionEpoch?.hasRenderedLoadedSnapshot == true else {
            return .none(placeholderMode: .none)
        }

        let prospectiveVisibleSections = DOMElementStyleDiffableSnapshotBuilder.visibleSections(
            sections: sections,
            expandedUnusedVariableSectionIDs: expandedUnusedVariableSectionIDs
        )
        let snapshot = DOMElementStyleDiffableSnapshotBuilder.makeSnapshot(
            visibleSections: prospectiveVisibleSections
        )
        guard Self.hasStructuralChanges(
            oldSectionIDs: visibleSectionIDs,
            oldItemIDs: visibleItemIDs,
            snapshot: snapshot
        ) == false else {
            return .none(placeholderMode: .none)
        }

        displayedSections = sections
        visibleSections = prospectiveVisibleSections
        let oldRenderContent = visibleRenderContent
        let newRenderContent = makeVisibleRenderContent()
        visibleRenderContent = newRenderContent
        let updatedSectionIDs = Self.updatedKeys(
            old: oldRenderContent.sectionContents,
            new: newRenderContent.sectionContents
        )
        let updatedPropertyIDs = Self.updatedKeys(
            old: oldRenderContent.propertyContents,
            new: newRenderContent.propertyContents
        )
        return .none(
            placeholderMode: .none,
            rebindVisiblePropertyRows: updatedPropertyIDs.isEmpty == false,
            updatedSectionIDs: updatedSectionIDs
        )
    }

    private func updateUnavailableSnapshot() -> SnapshotUpdate {
        let oldSectionIDs = visibleSectionIDs
        let oldItemIDs = visibleItemIDs
        expandedUnusedVariableSectionIDs.removeAll()
        displayedSections = nil
        visibleSections = []
        visibleRenderContent = .empty
        let snapshot = diffableSnapshot()
        let hasStructuralChanges = Self.hasStructuralChanges(
            oldSectionIDs: oldSectionIDs,
            oldItemIDs: oldItemIDs,
            snapshot: snapshot
        )
        if hasStructuralChanges {
            return .diff(
                snapshot: snapshot,
                animated: false,
                placeholderMode: .unavailable
            )
        }
        return .none(placeholderMode: .unavailable)
    }

    private func rebuildVisibleSections() {
        guard let displayedSections else {
            visibleSections = []
            return
        }
        let currentSectionIDs = Set(displayedSections.map(\.id))
        expandedUnusedVariableSectionIDs.formIntersection(currentSectionIDs)
        visibleSections = DOMElementStyleDiffableSnapshotBuilder.visibleSections(
            sections: displayedSections,
            expandedUnusedVariableSectionIDs: expandedUnusedVariableSectionIDs
        )
    }

    private func diffableSnapshot() -> NSDiffableDataSourceSnapshot<
        CSSStyleSection.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        DOMElementStyleDiffableSnapshotBuilder.makeSnapshot(
            visibleSections: visibleSections
        )
    }

    private func makeVisibleRenderContent() -> VisibleRenderContent {
        guard let displayedSections else {
            return .empty
        }

        var sectionsByID: [CSSStyleSection.ID: CSSStyleSection] = [:]
        for section in displayedSections {
            sectionsByID[section.id] = section
        }
        var sectionContents: [CSSStyleSection.ID: SectionRenderContent] = [:]
        var propertyContents: [
            DOMElementStylePresentationItemIdentifier: PropertyRenderContent
        ] = [:]

        for visibleSection in visibleSections {
            guard let section = sectionsByID[visibleSection.id] else {
                continue
            }
            sectionContents[visibleSection.id] = SectionRenderContent(section)
            for item in visibleSection.items {
                guard let property = property(for: item, in: section) else {
                    continue
                }
                propertyContents[item] = PropertyRenderContent(property)
            }
        }

        return VisibleRenderContent(
            sectionContents: sectionContents,
            propertyContents: propertyContents
        )
    }

    /// Keys present in both dictionaries whose content changed. Keys that
    /// only exist on one side are insertions or removals and are already
    /// handled by the structural diff.
    private static func updatedKeys<Key: Hashable, Content: Equatable>(
        old: [Key: Content],
        new: [Key: Content]
    ) -> Set<Key> {
        var updated = Set<Key>()
        for (key, newContent) in new {
            guard let oldContent = old[key], oldContent != newContent else {
                continue
            }
            updated.insert(key)
        }
        return updated
    }

    private static func hasStructuralChanges(
        oldSectionIDs: [CSSStyleSection.ID],
        oldItemIDs: [DOMElementStylePresentationItemIdentifier],
        snapshot: Snapshot
    ) -> Bool {
        oldSectionIDs != snapshot.sectionIdentifiers
            || oldItemIDs != snapshot.itemIdentifiers
    }
}
#endif

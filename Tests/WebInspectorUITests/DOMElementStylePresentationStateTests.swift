#if canImport(UIKit)
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorCoreConsoleNetwork
@testable import WebInspectorCoreDOMCSS
@testable import WebInspectorCoreRuntime
@testable import WebInspectorCoreSupport
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct DOMElementStyleSnapshotCoordinatorTests {
    @Test
    func coordinatorRequestsNonAnimatedDiffForInitialLoadedSelection() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeNodeStyles(sections: makeFlatStyleSections())
        coordinator.bindSelectedNodeStyles(nodeStyles)

        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .diff(animated: false))
        #expect(update.placeholderMode == .none)
        let snapshot = try loadedSnapshot(from: update)
        #expect(snapshot.sectionIdentifiers == coordinator.visibleSectionIDs)
        #expect(containsVisibleProperty(named: "margin", in: snapshot, coordinator: coordinator))
    }

    @Test
    func coordinatorReloadsWhenSwitchingToCachedSelectionStyles() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let bodyStyles = makeNodeStyles(sections: makeFlatStyleSections())
        coordinator.bindSelectedNodeStyles(bodyStyles)
        _ = coordinator.updateSelectedNodeStyles(bodyStyles)

        let inputStyles = makeNodeStyles(
            nodeLocalID: 2,
            sections: makeFlatStyleSections(
                nodeLocalID: 2,
                selector: "input",
                marginValue: "8px",
                marginText: "margin: 8px;"
            )
        )
        coordinator.bindSelectedNodeStyles(inputStyles)

        let update = coordinator.updateSelectedNodeStyles(inputStyles)

        #expect(update.applyMode == .reloadData)
        #expect(update.placeholderMode == .none)
        #expect(try loadedSnapshot(from: update).sectionIdentifiers == coordinator.visibleSectionIDs)
    }

    @Test
    func coordinatorReloadsSelectionReplacementWithMatchingDiffableIdentifiers() {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let oldStyles = makeNodeStyles(sections: makeFlatStyleSections())
        coordinator.bindSelectedNodeStyles(oldStyles)
        _ = coordinator.updateSelectedNodeStyles(oldStyles)

        let replacementStyles = makeNodeStyles(
            sections: makeFlatStyleSections(
                marginValue: "4px",
                marginText: "margin: 4px;"
            )
        )
        coordinator.bindSelectedNodeStyles(replacementStyles)

        let update = coordinator.updateSelectedNodeStyles(replacementStyles)

        #expect(update.applyMode == .reloadData)
        #expect(update.placeholderMode == .none)
    }

    @Test
    func coordinatorKeepsDisplayedRowsWhileSelectionHydratesThenReloadsLoadedReplacement() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let bodyStyles = makeNodeStyles(sections: makeFlatStyleSections())
        coordinator.bindSelectedNodeStyles(bodyStyles)
        _ = coordinator.updateSelectedNodeStyles(bodyStyles)

        let inputStyles = makeNodeStyles(nodeLocalID: 2, sections: [], phase: .loading)
        coordinator.bindSelectedNodeStyles(inputStyles)
        let loadingUpdate = coordinator.updateSelectedNodeStyles(inputStyles)

        #expect(loadingUpdate.applyMode == .none)
        #expect(loadingUpdate.snapshot == nil)
        #expect(loadingUpdate.placeholderMode == .none)
        #expect(coordinator.visibleSectionIDs.isEmpty == false)

        inputStyles.sections = makeFlatStyleSections(
            nodeLocalID: 2,
            selector: "input",
            marginValue: "8px",
            marginText: "margin: 8px;"
        )
        inputStyles.phase = .loaded
        let loadedUpdate = coordinator.updateSelectedNodeStyles(inputStyles)

        #expect(loadedUpdate.applyMode == .reloadData)
        #expect(loadedUpdate.placeholderMode == .none)
    }

    @Test
    func coordinatorAnimatesSameSelectionStructuralStyleChange() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeNodeStyles(sections: makeFlatStyleSections())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        nodeStyles.sections = makeStyleSections(inheritedOrdinal: 0)
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .diff(animated: true))
        let snapshot = try loadedSnapshot(from: update)
        #expect(snapshot.sectionIdentifiers.count == 2)
        #expect(containsVisibleProperty(named: "color", in: snapshot, coordinator: coordinator))
    }

    @Test
    func coordinatorDoesNotApplySnapshotForPropertyMutationWithoutTopologyChange() {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let sections = makeFlatStyleSections()
        let nodeStyles = makeNodeStyles(sections: sections)
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        let margin = sections[0].style.cssProperties[0]
        margin.value = "4px"
        margin.text = "margin: 4px;"

        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .none)
        #expect(update.snapshot == nil)
        #expect(update.placeholderMode == .none)
    }

    @Test
    func coordinatorReloadsWhenBackingPropertyObjectChangesWithoutStructuralIdentifiers() {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let sections = makeFlatStyleSections()
        let nodeStyles = makeNodeStyles(sections: sections)
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        let replacementProperties = makeFlatStyleSections(
            marginValue: "4px",
            marginText: "margin: 4px;"
        )[0].style.cssProperties
        sections[0].style.cssProperties = replacementProperties

        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .reloadData)
        #expect(update.placeholderMode == .none)
    }

    @Test
    func coordinatorRevealsHiddenUnusedVariablesWithAnimatedSnapshot() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let sections = makeStyleSections(inheritedOrdinal: 0)
        let nodeStyles = makeNodeStyles(sections: sections)
        coordinator.bindSelectedNodeStyles(nodeStyles)

        let initialSnapshot = try loadedSnapshot(from: coordinator.updateSelectedNodeStyles(nodeStyles))
        #expect(initialSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1))
        #expect(containsVisibleProperty(named: "--unused-a", in: initialSnapshot, coordinator: coordinator) == false)

        let inheritedSection = try #require(sections.first { $0.kind == .inheritedRule(ancestorIndex: 0) })
        let revealedUpdate = try #require(coordinator.revealHiddenUnusedVariables(in: inheritedSection.id))

        #expect(revealedUpdate.applyMode == .diff(animated: true))
        let revealedSnapshot = try loadedSnapshot(from: revealedUpdate)
        #expect(revealedSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1) == false)
        #expect(containsVisibleProperty(named: "--unused-a", in: revealedSnapshot, coordinator: coordinator))
    }

    @Test
    func coordinatorPrunesExpandedUnusedVariableSectionsAfterSectionRefresh() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let oldSections = makeStyleSections(inheritedOrdinal: 0, unusedVariableName: "--unused-a")
        let nodeStyles = makeNodeStyles(sections: oldSections)
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        let oldInheritedSection = try #require(oldSections.first { $0.kind == .inheritedRule(ancestorIndex: 0) })
        _ = try #require(coordinator.revealHiddenUnusedVariables(in: oldInheritedSection.id))

        let newSections = makeStyleSections(inheritedOrdinal: 1, unusedVariableName: "--unused-b")
        nodeStyles.sections = newSections
        let refreshedUpdate = coordinator.updateSelectedNodeStyles(nodeStyles)
        let refreshedSnapshot = try loadedSnapshot(from: refreshedUpdate)

        #expect(refreshedUpdate.applyMode == .diff(animated: true))
        #expect(coordinator.section(for: oldInheritedSection.id) == nil)
        #expect(refreshedSnapshot.sectionIdentifiers == coordinator.visibleSectionIDs)
        #expect(refreshedSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1))
        #expect(containsVisibleProperty(named: "--unused-b", in: refreshedSnapshot, coordinator: coordinator) == false)
        #expect(coordinator.revealHiddenUnusedVariables(in: oldInheritedSection.id) == nil)
    }

    private func loadedSnapshot(
        from update: DOMElementStyleSnapshotCoordinator.SnapshotUpdate
    ) throws -> NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        try #require(update.snapshot)
    }

    private func containsVisibleProperty(
        named name: String,
        in snapshot: NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >,
        coordinator: DOMElementStyleSnapshotCoordinator
    ) -> Bool {
        snapshot.itemIdentifiers.contains { item in
            guard let section = coordinator.section(for: item.sectionID),
                  let property = coordinator.property(for: item, in: section) else {
                return false
            }
            return property.name == name
        }
    }

    private func makeNodeStyles(
        nodeLocalID: Int = 1,
        sections: [CSSStyle.Section],
        phase: CSSNodeStyles.Phase = .loaded
    ) -> CSSNodeStyles {
        let identity = makeIdentity(nodeLocalID: nodeLocalID)
        return CSSNodeStyles(
            id: CSSNodeStyles.ID(
                nodeID: identity.nodeID,
                targetID: identity.targetID,
                documentID: identity.documentID,
                protocolNodeID: .init(nodeLocalID)
            ),
            phase: phase,
            sections: sections
        )
    }

    private func makeFlatStyleSections(
        nodeLocalID: Int = 1,
        selector: String = "body",
        marginValue: String = "0",
        marginText: String = "margin: 0;"
    ) -> [CSSStyle.Section] {
        let nodeID = makeIdentity(nodeLocalID: nodeLocalID).nodeID
        let styleSheetID = CSSStyleSheet.ID("flat-styles")
        let styleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 0)

        return [
            CSSStyle.Section(
                id: CSSStyle.Section.ID(nodeID: nodeID, kind: .rule, ordinal: 0),
                kind: .rule,
                title: selector,
                style: CSSStyle(
                    id: styleID,
                    cssProperties: [
                        property(
                            id: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
                            name: "margin",
                            value: marginValue,
                            text: marginText
                        ),
                        property(
                            id: CSSProperty.ID(styleID: styleID, propertyIndex: 1),
                            name: "padding",
                            value: "8px",
                            text: "padding: 8px;"
                        ),
                    ]
                ),
                isEditable: true
            ),
        ]
    }

    private func makeStyleSections(
        nodeLocalID: Int = 1,
        inheritedOrdinal: Int,
        unusedVariableName: String = "--unused-a"
    ) -> [CSSStyle.Section] {
        let nodeID = makeIdentity(nodeLocalID: nodeLocalID).nodeID
        let styleSheetID = CSSStyleSheet.ID("styles")

        let ruleStyleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 0)
        let inheritedStyleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: inheritedOrdinal + 1)

        return [
            CSSStyle.Section(
                id: CSSStyle.Section.ID(nodeID: nodeID, kind: .rule, ordinal: 0),
                kind: .rule,
                title: "body",
                style: CSSStyle(
                    id: ruleStyleID,
                    cssProperties: [
                        property(
                            id: CSSProperty.ID(styleID: ruleStyleID, propertyIndex: 0),
                            name: "color",
                            value: "var(--used)",
                            text: "color: var(--used);"
                        ),
                    ]
                ),
                isEditable: true
            ),
            CSSStyle.Section(
                id: CSSStyle.Section.ID(
                    nodeID: nodeID,
                    kind: .inheritedRule(ancestorIndex: inheritedOrdinal),
                    ordinal: inheritedOrdinal
                ),
                kind: .inheritedRule(ancestorIndex: inheritedOrdinal),
                title: ":root",
                style: CSSStyle(
                    id: inheritedStyleID,
                    cssProperties: [
                        property(
                            id: CSSProperty.ID(styleID: inheritedStyleID, propertyIndex: 0),
                            name: "--used",
                            value: "#111",
                            text: "--used: #111;"
                        ),
                        property(
                            id: CSSProperty.ID(styleID: inheritedStyleID, propertyIndex: 1),
                            name: unusedVariableName,
                            value: "red",
                            text: "\(unusedVariableName): red;"
                        ),
                    ]
                ),
                isEditable: true
            ),
        ]
    }

    private func makeIdentity(
        nodeLocalID: Int
    ) -> (
        targetID: ProtocolTarget.ID,
        documentID: DOMDocument.ID,
        nodeID: DOMNode.ID
    ) {
        let targetID = ProtocolTarget.ID("page-main")
        let documentID = DOMDocument.ID(
            targetID: targetID,
            localDocumentLifetimeID: .init(1)
        )
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: .init(nodeLocalID))
        return (targetID, documentID, nodeID)
    }

    private func property(
        id: CSSProperty.ID,
        name: String,
        value: String,
        text: String
    ) -> CSSProperty {
        CSSProperty(
            id: id,
            name: name,
            value: value,
            text: text,
            status: .active,
            isEditable: true
        )
    }
}
}

@MainActor
private extension [DOMElementStylePresentationItemIdentifier] {
    func containsHiddenUnusedVariables(count: Int) -> Bool {
        contains { item in
            guard case let .hiddenUnusedVariables(hiddenCount) = item.kind else {
                return false
            }
            return hiddenCount == count
        }
    }
}
#endif

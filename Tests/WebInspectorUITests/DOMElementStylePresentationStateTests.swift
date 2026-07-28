#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorProxyKit
@testable import WebInspectorDataKit
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct DOMElementStyleSnapshotCoordinatorTests {
    /// Keeps the weak `CSSStyles.modelContext` alive for the test lifetime.
    private let modelContext = WebInspectorContext.preview(isolation: MainActor.shared)

    @Test
    func coordinatorRequestsNonAnimatedDiffForInitialLoadedSelection() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
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
        let bodyStyles = makeStyles(nodeID: "node-body")
        load(bodyStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(bodyStyles)
        _ = coordinator.updateSelectedNodeStyles(bodyStyles)

        let inputStyles = makeStyles(nodeID: "node-input")
        load(
            inputStyles,
            with: makeFlatMatchedStyles(
                selector: "input",
                marginValue: "8px",
                marginText: "margin: 8px;",
                styleIDSuffix: "input"
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
        let oldStyles = makeStyles()
        load(oldStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(oldStyles)
        _ = coordinator.updateSelectedNodeStyles(oldStyles)

        let replacementStyles = makeStyles()
        load(
            replacementStyles,
            with: makeFlatMatchedStyles(
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
        let bodyStyles = makeStyles(nodeID: "node-body")
        load(bodyStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(bodyStyles)
        _ = coordinator.updateSelectedNodeStyles(bodyStyles)

        let inputStyles = makeStyles(nodeID: "node-input")
        coordinator.bindSelectedNodeStyles(inputStyles)
        let loadingUpdate = coordinator.updateSelectedNodeStyles(inputStyles)

        #expect(inputStyles.phase == .loading)
        #expect(loadingUpdate.applyMode == .none)
        #expect(loadingUpdate.snapshot == nil)
        #expect(loadingUpdate.placeholderMode == .none)
        #expect(coordinator.visibleSectionIDs.isEmpty == false)

        load(
            inputStyles,
            with: makeFlatMatchedStyles(
                selector: "input",
                marginValue: "8px",
                marginText: "margin: 8px;",
                styleIDSuffix: "input"
            )
        )
        let loadedUpdate = coordinator.updateSelectedNodeStyles(inputStyles)

        #expect(loadedUpdate.applyMode == .reloadData)
        #expect(loadedUpdate.placeholderMode == .none)
    }

    @Test
    func coordinatorAnimatesSameSelectionStructuralStyleChange() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        load(nodeStyles, with: makeVariablesMatchedStyles())
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .diff(animated: true))
        let snapshot = try loadedSnapshot(from: update)
        #expect(snapshot.sectionIdentifiers.count == 2)
        #expect(containsVisibleProperty(named: "color", in: snapshot, coordinator: coordinator))
    }

    /// Value-world replacement for the legacy in-place property mutation
    /// policy: rows no longer observe property objects, so a same-identity
    /// content change must surface as a reconfigure apply.
    @Test
    func coordinatorReconfiguresRowsForPropertyContentChangeWithoutStructuralChange() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        let initialSnapshot = try loadedSnapshot(from: coordinator.updateSelectedNodeStyles(nodeStyles))

        load(
            nodeStyles,
            with: makeFlatMatchedStyles(
                marginValue: "4px",
                marginText: "margin: 4px;"
            )
        )
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .diff(animated: false))
        #expect(update.placeholderMode == .none)
        let snapshot = try loadedSnapshot(from: update)
        #expect(snapshot.sectionIdentifiers == initialSnapshot.sectionIdentifiers)
        #expect(snapshot.itemIdentifiers == initialSnapshot.itemIdentifiers)
        let reconfiguredItems = snapshot.reconfiguredItemIdentifiers
        #expect(reconfiguredItems.count == 1)
        let reconfiguredItem = try #require(reconfiguredItems.first)
        let section = try #require(coordinator.section(for: reconfiguredItem.sectionID))
        #expect(coordinator.property(for: reconfiguredItem, in: section)?.name == "margin")
    }

    /// DataKit's `applySetStyleText` rewrites sections in place and marks
    /// the styles `.needsRefresh`; the rewritten declaration text and the
    /// modified-by-inspector badge must reach the rows before the follow-up
    /// refresh lands.
    @Test
    func coordinatorReconfiguresSameSelectionContentDuringNeedsRefresh() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        let initialSnapshot = try loadedSnapshot(from: coordinator.updateSelectedNodeStyles(nodeStyles))

        load(
            nodeStyles,
            with: makeFlatMatchedStyles(
                marginValue: "4px",
                marginText: "/* margin: 4px; */"
            )
        )
        nodeStyles.markNeedsRefresh()
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .diff(animated: false))
        let snapshot = try loadedSnapshot(from: update)
        #expect(snapshot.sectionIdentifiers == initialSnapshot.sectionIdentifiers)
        #expect(snapshot.itemIdentifiers == initialSnapshot.itemIdentifiers)
        #expect(snapshot.reconfiguredItemIdentifiers.count == 1)
    }

    /// Structure stays frozen while the styles are stale; structural changes
    /// wait for the follow-up refresh to load.
    @Test
    func coordinatorKeepsDisplayedStructureForStructuralChangesDuringNeedsRefresh() {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)
        let renderedSectionIDs = coordinator.visibleSectionIDs

        load(nodeStyles, with: makeVariablesMatchedStyles())
        nodeStyles.markNeedsRefresh()
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .none)
        #expect(update.snapshot == nil)
        #expect(coordinator.visibleSectionIDs == renderedSectionIDs)
    }

    @Test
    func coordinatorDoesNotApplySnapshotWhenReloadedContentIsUnchanged() {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        load(nodeStyles, with: makeFlatMatchedStyles())
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .none)
        #expect(update.snapshot == nil)
        #expect(update.placeholderMode == .none)
        #expect(update.updatedSectionIDs.isEmpty)
    }

    /// Header content changes with stable section identity require no
    /// snapshot apply; they are reported through `updatedSectionIDs` so the
    /// view controller re-binds visible header views.
    @Test
    func coordinatorReportsHeaderContentChangeWithoutSnapshotApply() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeFlatMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)
        let sectionID = try #require(coordinator.visibleSectionIDs.first)

        load(nodeStyles, with: makeFlatMatchedStyles(selector: ".content"))
        let update = coordinator.updateSelectedNodeStyles(nodeStyles)

        #expect(update.applyMode == .none)
        #expect(update.snapshot == nil)
        #expect(update.updatedSectionIDs == [sectionID])
        #expect(coordinator.section(for: sectionID)?.title == ".content")
    }

    @Test
    func coordinatorRevealsHiddenUnusedVariablesWithAnimatedSnapshot() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(nodeStyles, with: makeVariablesMatchedStyles())
        coordinator.bindSelectedNodeStyles(nodeStyles)

        let initialSnapshot = try loadedSnapshot(from: coordinator.updateSelectedNodeStyles(nodeStyles))
        #expect(initialSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1))
        #expect(containsVisibleProperty(named: "--unused-a", in: initialSnapshot, coordinator: coordinator) == false)

        let inheritedSection = try #require(
            nodeStyles.sections.first { $0.kind == .inheritedRule(ancestorIndex: 0) }
        )
        let revealedUpdate = try #require(coordinator.revealHiddenUnusedVariables(in: inheritedSection.id))

        #expect(revealedUpdate.applyMode == .diff(animated: true))
        let revealedSnapshot = try loadedSnapshot(from: revealedUpdate)
        #expect(revealedSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1) == false)
        #expect(containsVisibleProperty(named: "--unused-a", in: revealedSnapshot, coordinator: coordinator))
    }

    @Test
    func coordinatorPrunesExpandedUnusedVariableSectionsAfterSectionRefresh() throws {
        let coordinator = DOMElementStyleSnapshotCoordinator()
        let nodeStyles = makeStyles()
        load(
            nodeStyles,
            with: makeVariablesMatchedStyles(inheritedAncestorIndex: 0, unusedVariableName: "--unused-a")
        )
        coordinator.bindSelectedNodeStyles(nodeStyles)
        _ = coordinator.updateSelectedNodeStyles(nodeStyles)

        let oldInheritedSection = try #require(
            nodeStyles.sections.first { $0.kind == .inheritedRule(ancestorIndex: 0) }
        )
        _ = try #require(coordinator.revealHiddenUnusedVariables(in: oldInheritedSection.id))

        load(
            nodeStyles,
            with: makeVariablesMatchedStyles(inheritedAncestorIndex: 1, unusedVariableName: "--unused-b")
        )
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
        CSSStyleSection.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        try #require(update.snapshot)
    }

    private func containsVisibleProperty(
        named name: String,
        in snapshot: NSDiffableDataSourceSnapshot<
            CSSStyleSection.ID,
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

    private func makeStyles(nodeID: String = "node-1") -> CSSStyles {
        CSSStyles(
            nodeID: DOMNode.ID(DOM.Node.ID(nodeID)),
            modelContext: modelContext
        )
    }

    private func load(_ styles: CSSStyles, with matchedStyles: CSS.MatchedStyles) {
        styles.load(
            matchedStyles: matchedStyles,
            inlineStyles: CSS.InlineStyles(),
            computedProperties: []
        )
    }

    private func makeFlatMatchedStyles(
        selector: String = "body",
        marginValue: String = "0",
        marginText: String = "margin: 0;",
        styleIDSuffix: String = "flat"
    ) -> CSS.MatchedStyles {
        let styleID = "style-\(styleIDSuffix)"
        let style = CSS.Style(
            id: CSS.Style.ID(styleID),
            properties: [
                property(id: "\(styleID):0", name: "margin", value: marginValue, text: marginText),
                property(id: "\(styleID):1", name: "padding", value: "8px", text: "padding: 8px;"),
            ],
            cssText: "\(marginText)\npadding: 8px;",
            isEditable: true
        )
        return CSS.MatchedStyles(matchedRules: [
            CSS.Rule(
                id: CSS.Rule.ID("rule-\(styleIDSuffix)"),
                selectorList: CSS.Rule.SelectorList(selectors: [selector], text: selector),
                origin: CSS.Origin(rawValue: "author"),
                style: style
            ),
        ])
    }

    private func makeVariablesMatchedStyles(
        inheritedAncestorIndex: Int = 0,
        unusedVariableName: String = "--unused-a"
    ) -> CSS.MatchedStyles {
        let bodyStyle = CSS.Style(
            id: CSS.Style.ID("style-variables-body"),
            properties: [
                property(
                    id: "style-variables-body:0",
                    name: "color",
                    value: "var(--used)",
                    text: "color: var(--used);"
                ),
            ],
            cssText: "color: var(--used);",
            isEditable: true
        )
        let rootStyle = CSS.Style(
            id: CSS.Style.ID("style-variables-root"),
            properties: [
                property(
                    id: "style-variables-root:0",
                    name: "--used",
                    value: "#111",
                    text: "--used: #111;"
                ),
                property(
                    id: "style-variables-root:1",
                    name: unusedVariableName,
                    value: "red",
                    text: "\(unusedVariableName): red;"
                ),
            ],
            cssText: "--used: #111;\n\(unusedVariableName): red;",
            isEditable: true
        )
        let inheritedEntries = Array(
            repeating: CSS.MatchedStyles.InheritedEntry(),
            count: inheritedAncestorIndex
        ) + [
            CSS.MatchedStyles.InheritedEntry(matchedRules: [
                CSS.Rule(
                    id: CSS.Rule.ID("rule-variables-root"),
                    selectorList: CSS.Rule.SelectorList(selectors: [":root"], text: ":root"),
                    origin: CSS.Origin(rawValue: "author"),
                    style: rootStyle
                ),
            ]),
        ]
        return CSS.MatchedStyles(
            matchedRules: [
                CSS.Rule(
                    id: CSS.Rule.ID("rule-variables-body"),
                    selectorList: CSS.Rule.SelectorList(selectors: ["body"], text: "body"),
                    origin: CSS.Origin(rawValue: "author"),
                    style: bodyStyle
                ),
            ],
            inherited: inheritedEntries
        )
    }

    private func property(
        id: String,
        name: String,
        value: String,
        text: String
    ) -> CSS.Property {
        CSS.Property(
            id: CSS.Property.ID(id),
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

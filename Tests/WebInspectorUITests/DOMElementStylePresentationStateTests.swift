#if canImport(UIKit)
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct DOMElementStylePresentationStateTests {
    @Test
    func presentationStateRevealsHiddenUnusedVariablesWithTransientSnapshot() throws {
        let state = DOMElementStylePresentationState()
        let sections = makeStyleSections(inheritedOrdinal: 0)
        let nodeStyles = makeNodeStyles(sections: sections)

        let initialSnapshot = try loadedSnapshot(from: state.render(nodeStyles))
        #expect(initialSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1))
        #expect(containsVisibleProperty(named: "--unused-a", in: initialSnapshot, state: state) == false)

        let inheritedSection = try #require(sections.first { $0.kind == .inheritedRule(ancestorIndex: 0) })
        let revealedSnapshot = try #require(state.showHiddenUnusedVariables(in: inheritedSection.id))
        #expect(revealedSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1) == false)
        #expect(containsVisibleProperty(named: "--unused-a", in: revealedSnapshot, state: state))
    }

    @Test
    func presentationStatePrunesExpandedUnusedVariableSectionsAfterSectionRefresh() throws {
        let state = DOMElementStylePresentationState()
        let oldSections = makeStyleSections(inheritedOrdinal: 0, unusedVariableName: "--unused-a")
        let nodeStyles = makeNodeStyles(sections: oldSections)
        _ = try loadedSnapshot(from: state.render(nodeStyles))

        let oldInheritedSection = try #require(oldSections.first { $0.kind == .inheritedRule(ancestorIndex: 0) })
        _ = try #require(state.showHiddenUnusedVariables(in: oldInheritedSection.id))

        let newSections = makeStyleSections(inheritedOrdinal: 1, unusedVariableName: "--unused-b")
        nodeStyles.sections = newSections
        let refreshedSnapshot = try loadedSnapshot(from: state.render(nodeStyles))

        #expect(state.section(for: oldInheritedSection.id) == nil)
        #expect(refreshedSnapshot.sectionIdentifiers == state.visibleSectionIDs)
        #expect(refreshedSnapshot.itemIdentifiers.containsHiddenUnusedVariables(count: 1))
        #expect(containsVisibleProperty(named: "--unused-b", in: refreshedSnapshot, state: state) == false)
        #expect(state.showHiddenUnusedVariables(in: oldInheritedSection.id) == nil)
    }

    private func loadedSnapshot(
        from result: DOMElementStylePresentationState.RenderResult
    ) throws -> NSDiffableDataSourceSnapshot<
        CSSStyle.Section.ID,
        DOMElementStylePresentationItemIdentifier
    > {
        guard case let .loaded(snapshot) = result else {
            Issue.record("Expected loaded style presentation state")
            throw TestFailure()
        }
        return snapshot
    }

    private func containsVisibleProperty(
        named name: String,
        in snapshot: NSDiffableDataSourceSnapshot<
            CSSStyle.Section.ID,
            DOMElementStylePresentationItemIdentifier
        >,
        state: DOMElementStylePresentationState
    ) -> Bool {
        snapshot.itemIdentifiers.contains { item in
            guard let section = state.section(for: item.sectionID),
                  let property = state.property(for: item, in: section) else {
                return false
            }
            return property.name == name
        }
    }

    private func makeNodeStyles(sections: [CSSStyle.Section]) -> CSSNodeStyles {
        let targetID = ProtocolTarget.ID("page-main")
        let documentID = DOMDocument.ID(
            targetID: targetID,
            localDocumentLifetimeID: .init(1)
        )
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: .init(1))
        return CSSNodeStyles(
            id: CSSNodeStyles.ID(
                nodeID: nodeID,
                targetID: targetID,
                documentID: documentID,
                protocolNodeID: .init(1)
            ),
            phase: .loaded,
            sections: sections
        )
    }

    private func makeStyleSections(
        inheritedOrdinal: Int,
        unusedVariableName: String = "--unused-a"
    ) -> [CSSStyle.Section] {
        let targetID = ProtocolTarget.ID("page-main")
        let documentID = DOMDocument.ID(
            targetID: targetID,
            localDocumentLifetimeID: .init(1)
        )
        let nodeID = DOMNode.ID(documentID: documentID, nodeID: .init(1))
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

private struct TestFailure: Error {}

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

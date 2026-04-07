#if canImport(UIKit)
import Foundation
import Testing
@testable import WebInspectorEngine
@testable import WebInspectorUI

@MainActor
struct AttributeDraftStateTests {
    @Test
    func reconcileRefreshesCleanDraftForExternalUpdate() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")

        let result = state.reconcile(externalValue: "after")

        #expect(result == .refreshClean)
        #expect(state.baselineValue == "after")
        #expect(state.draftValue == "after")
        #expect(state.isDirty == false)
    }

    @Test
    func reconcilePreservesDirtyDraftForExternalUpdate() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("draft")

        let result = state.reconcile(externalValue: "after")

        #expect(result == .preserveDirty)
        #expect(state.baselineValue == "after")
        #expect(state.draftValue == "draft")
        #expect(state.isDirty == true)
    }

    @Test
    func markCommittedResetsDirtyState() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("after")

        state.markCommitted()

        #expect(state.baselineValue == "after")
        #expect(state.draftValue == "after")
        #expect(state.isDirty == false)
    }

    @Test
    func reconcilePreservesCommittedInlineDraftUntilMutationEchoMatches() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("after")
        state.markAwaitingModelEcho(
            submittedValue: "after",
            previousValue: "before"
        )

        let staleResult = state.reconcile(externalValue: "before")

        #expect(staleResult == .preserveDirty)
        #expect(state.baselineValue == "before")
        #expect(state.draftValue == "after")
        #expect(state.isDirty == true)
        #expect(state.isAwaitingModelEcho == true)

        let echoedResult = state.reconcile(externalValue: "after")

        #expect(echoedResult == .refreshClean)
        #expect(state.baselineValue == "after")
        #expect(state.draftValue == "after")
        #expect(state.isDirty == false)
        #expect(state.phase == .clean)
    }

    @Test
    func reconcileTracksLatestBaselineWhilePreservingDirtyDraft() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("draft")

        let result = state.reconcile(externalValue: "server")

        #expect(result == .preserveDirty)
        #expect(state.baselineValue == "server")
        #expect(state.draftValue == "draft")
        #expect(state.isDirty == true)
    }

    @Test
    func reconcileMarksDirtyDraftCommittedWhenExternalValueMatches() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("draft")

        let result = state.reconcile(externalValue: "draft")

        #expect(result == .refreshClean)
        #expect(state.baselineValue == "draft")
        #expect(state.draftValue == "draft")
        #expect(state.isDirty == false)
    }

    @Test
    func reconcileClearsCleanDraftWhenExternalValueDisappears() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")

        let result = state.reconcile(externalValue: nil)

        #expect(result == .clear)
        #expect(state.baselineValue.isEmpty)
        #expect(state.draftValue.isEmpty)
    }

    @Test
    func reconcilePreservesDirtyDraftWhenExternalValueDisappears() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("draft")

        let result = state.reconcile(externalValue: nil)

        #expect(result == .preserveDirty)
        #expect(state.baselineValue == "before")
        #expect(state.draftValue == "draft")
        #expect(state.baselineExists == false)
        #expect(state.isDirty == true)
    }

    @Test
    func reconcileKeepsDeletedAttributeDirtyWhenDraftMatchesPreviousValue() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("draft")
        _ = state.reconcile(externalValue: "server")

        let result = state.reconcile(externalValue: nil)

        #expect(result == .preserveDirty)
        state.updateDraft("server")
        #expect(state.baselineExists == false)
        #expect(state.draftValue == "server")
        #expect(state.isDirty == true)
    }

    @Test
    func reconcileKeepsDeletedAttributeDirtyWhenDraftIsEmpty() {
        var state = WIDOMAttributeDraftState()
        state.begin(value: "before")
        state.updateDraft("")

        let result = state.reconcile(externalValue: nil)

        #expect(result == .preserveDirty)
        #expect(state.baselineExists == false)
        #expect(state.preservesDeletedBaseline == true)
        #expect(state.draftValue.isEmpty)
        #expect(state.isDirty == true)
    }

    @Test
    func draftSessionReconcileDefersClearForTransientDeselection() {
        let session = WIDOMAttributeDraftSession(
            key: .init(
                nodeID: .init(documentIdentity: UUID(), localID: 42),
                attributeName: "class"
            ),
            value: "before"
        )

        let result = reconcileAttributeDraftSession(
            session,
            selectedNode: nil,
            allowTransientDeselection: true
        )

        #expect(result == .deferClear)
    }

    @Test
    func draftSessionReconcileKeepsDraftWhenSameLogicalNodeReturnsAfterTransientDeselection() {
        let nodeID = DOMNodeModel.ID(documentIdentity: UUID(), localID: 42)
        let node = DOMNodeModel(
            id: nodeID,
            backendNodeID: 42,
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            nodeValue: "",
            attributes: [.init(nodeId: 42, name: "class", value: "server")],
            childCount: 0
        )
        var session = WIDOMAttributeDraftSession(
            key: .init(nodeID: nodeID, attributeName: "class"),
            value: "before"
        )
        session.updateDraft("draft")

        let result = reconcileAttributeDraftSession(
            session,
            selectedNode: node,
            allowTransientDeselection: false
        )

        guard case let .keep(updatedSession) = result else {
            Issue.record("Expected draft session to survive same-node reselection")
            return
        }
        #expect(updatedSession.key == session.key)
        #expect(updatedSession.draftValue == "draft")
        #expect(updatedSession.isDirty == true)
    }

    @Test
    func attributeSheetSaveCompletionKeepsNewerDraftForSameKey() {
        let key = WIDOMAttributeDraftKey(
            nodeID: .init(documentIdentity: UUID(), localID: 42),
            attributeName: "class"
        )
        var session = WIDOMAttributeDraftSession(key: key, value: "before")
        session.updateDraft("newer")

        let resolvedSession = resolveAttributeSheetDraftSessionAfterSuccessfulSave(
            session,
            key: key,
            submittedValue: "before"
        )

        #expect(resolvedSession?.key == key)
        #expect(resolvedSession?.draftValue == "newer")
        #expect(resolvedSession?.isDirty == true)
    }

    @Test
    func inlineSaveTransitionsMatchingDraftToAwaitingModelEcho() {
        let key = WIDOMAttributeDraftKey(
            nodeID: .init(documentIdentity: UUID(), localID: 42),
            attributeName: "class"
        )
        var session = WIDOMAttributeDraftSession(key: key, value: "before")
        session.updateDraft("draft")

        let resolvedSession = resolveInlineAttributeDraftSessionAfterSuccessfulSave(
            currentSession: session,
            key: key,
            submittedValue: "draft",
            previousValue: "before"
        )

        #expect(resolvedSession?.draftValue == "draft")
        #expect(resolvedSession?.isAwaitingModelEcho == true)
    }

    @Test
    func inlineSaveDoesNotRecreateClearedSessionAfterModelEcho() {
        let key = WIDOMAttributeDraftKey(
            nodeID: .init(documentIdentity: UUID(), localID: 42),
            attributeName: "class"
        )

        let resolvedSession = resolveInlineAttributeDraftSessionAfterSuccessfulSave(
            currentSession: nil,
            key: key,
            submittedValue: "draft",
            previousValue: "before"
        )

        #expect(resolvedSession == nil)
    }
}
#endif

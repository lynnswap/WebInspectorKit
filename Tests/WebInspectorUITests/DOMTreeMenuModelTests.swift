#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
struct DOMTreeMenuModelTests {
    @Test
    func singleNodeSelectionEnablesTextAndNodeActions() throws {
        let fixture = try makeMenuFixture()
        let model = DOMTreeMenuModel(
            dom: fixture.session,
            copyNodeTextAction: { _, kind in
                switch kind {
                case .html:
                    return "<div></div>"
                case .selectorPath:
                    return "html > body > div"
                case .xPath:
                    return "/html/body/div"
                }
            },
            deleteNodesAction: { _, _ in true }
        )

        model.configure(
            nodeIDs: [fixture.divID],
            selectedText: "data-testid",
            undoManager: nil,
            localMarkupTextByNodeID: [fixture.divID: "<div id=\"start-of-content\"></div>"],
            clearLocalSelection: {}
        )

        #expect(model.showsSelectedTextCopy)
        #expect(model.canCopySelectedText)
        #expect(model.canCopyHTML)
        #expect(model.showsSingleNodeCopyActions)
        #expect(model.canCopySelectorPath)
        #expect(model.canCopyXPath)
        #expect(model.deleteTitle == "Delete Node")
        #expect(model.canDelete)
    }

    @Test
    func singleNodeSelectionDisablesDeleteWhenHandlerIsMissing() throws {
        let fixture = try makeMenuFixture()
        let model = DOMTreeMenuModel(
            dom: fixture.session,
            copyNodeTextAction: nil,
            deleteNodesAction: nil
        )

        model.configure(
            nodeIDs: [fixture.divID],
            selectedText: nil,
            undoManager: nil,
            localMarkupTextByNodeID: [fixture.divID: "<div id=\"start-of-content\"></div>"],
            clearLocalSelection: {}
        )

        #expect(!model.showsSelectedTextCopy)
        #expect(model.canCopyHTML)
        #expect(model.showsSingleNodeCopyActions)
        #expect(model.canCopySelectorPath)
        #expect(model.canCopyXPath)
        #expect(model.deleteTitle == "Delete Node")
        #expect(!model.canDelete)
    }

    @Test
    func multiNodeSelectionUsesSharedHTMLCopyAndMultiDeleteState() throws {
        let fixture = try makeMenuFixture()
        let model = DOMTreeMenuModel(
            dom: fixture.session,
            copyNodeTextAction: { _, kind in
                kind == .html ? "<node></node>" : nil
            },
            deleteNodesAction: { _, _ in true }
        )

        model.configure(
            nodeIDs: [fixture.divID, fixture.inputID],
            selectedText: nil,
            undoManager: nil,
            localMarkupTextByNodeID: [
                fixture.divID: "<div id=\"start-of-content\"></div>",
                fixture.inputID: "<input disabled>",
            ],
            clearLocalSelection: {}
        )

        #expect(!model.showsSelectedTextCopy)
        #expect(model.canCopyHTML)
        #expect(!model.showsSingleNodeCopyActions)
        #expect(!model.canCopySelectorPath)
        #expect(!model.canCopyXPath)
        #expect(model.deleteTitle == "Delete Nodes")
        #expect(model.canDelete)
    }

    @Test
    func deleteSelectionClearsLocalSelectionOnlyAfterSuccessfulAction() async throws {
        let fixture = try makeMenuFixture()
        var clearCount = 0
        let failingModel = DOMTreeMenuModel(
            dom: fixture.session,
            copyNodeTextAction: nil,
            deleteNodesAction: { _, _ in false }
        )

        failingModel.configure(
            nodeIDs: [fixture.divID],
            selectedText: nil,
            undoManager: nil,
            localMarkupTextByNodeID: [:],
            clearLocalSelection: {
                clearCount += 1
            }
        )

        let failingTask = try #require(failingModel.deleteSelection())
        await failingTask.value
        #expect(clearCount == 0)

        var deletedNodeIDs: [DOMNode.ID] = []
        let successfulModel = DOMTreeMenuModel(
            dom: fixture.session,
            copyNodeTextAction: nil,
            deleteNodesAction: { nodeIDs, _ in
                deletedNodeIDs = nodeIDs
                return true
            }
        )

        successfulModel.configure(
            nodeIDs: [fixture.divID],
            selectedText: nil,
            undoManager: nil,
            localMarkupTextByNodeID: [:],
            clearLocalSelection: {
                clearCount += 1
            }
        )

        let successfulTask = try #require(successfulModel.deleteSelection())
        await successfulTask.value
        #expect(deletedNodeIDs == [fixture.divID])
        #expect(clearCount == 1)
    }
}

private struct DOMTreeMenuModelFixture {
    var session: DOMSession
    var divID: DOMNode.ID
    var inputID: DOMNode.ID
}

@MainActor
private func makeMenuFixture() throws -> DOMTreeMenuModelFixture {
    let targetID = ProtocolTargetIdentifier("page-main")
    let session = DOMSession()
    session.applyTargetCreated(
        ProtocolTargetRecord(
            id: targetID,
            kind: .page,
            frameID: DOMFrameIdentifier("main-frame")
        ),
        makeCurrentMainPage: true
    )
    _ = session.replaceDocumentRoot(menuFixtureDocument(), targetID: targetID)

    let divID = try #require(
        session.snapshot().currentNodeIDByKey[DOMNodeCurrentKey(targetID: targetID, nodeID: .init(7))]
    )
    let inputID = try #require(
        session.snapshot().currentNodeIDByKey[DOMNodeCurrentKey(targetID: targetID, nodeID: .init(12))]
    )
    return DOMTreeMenuModelFixture(session: session, divID: divID, inputID: inputID)
}

private func menuFixtureDocument() -> DOMNodePayload {
    DOMNodePayload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNodePayload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    DOMNodePayload(
                        nodeID: .init(6),
                        nodeType: .element,
                        nodeName: "BODY",
                        localName: "body",
                        regularChildren: .loaded([
                            DOMNodePayload(
                                nodeID: .init(7),
                                nodeType: .element,
                                nodeName: "DIV",
                                localName: "div",
                                attributes: [
                                    DOMAttribute(name: "id", value: "start-of-content"),
                                    DOMAttribute(name: "data-testid", value: "cellInnerDiv"),
                                ]
                            ),
                            DOMNodePayload(
                                nodeID: .init(12),
                                nodeType: .element,
                                nodeName: "INPUT",
                                localName: "input",
                                attributes: [DOMAttribute(name: "disabled", value: "")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}
#endif

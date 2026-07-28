#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorDataKit
@testable import WebInspectorProxyKit
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
struct DOMTreeMenuModelTests {
    @Test
    func singleNodeSelectionEnablesTextAndNodeActions() throws {
        let fixture = try makeMenuFixture()
        let model = DOMTreeMenuModel(
            context: fixture.context,
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
        #expect(model.canDelete)
    }

    @Test
    func singleNodeSelectionDisablesDeleteWhenHandlerIsMissing() throws {
        let fixture = try makeMenuFixture()
        let model = DOMTreeMenuModel(
            context: fixture.context,
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
        #expect(!model.canDelete)
    }

    @Test
    func multiNodeSelectionUsesSharedHTMLCopyAndMultiDeleteState() throws {
        let fixture = try makeMenuFixture()
        let model = DOMTreeMenuModel(
            context: fixture.context,
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
        #expect(model.canDelete)
    }

    @Test
    func deleteSelectionClearsLocalSelectionOnlyAfterSuccessfulAction() async throws {
        let fixture = try makeMenuFixture()
        var clearCount = 0
        let failingModel = DOMTreeMenuModel(
            context: fixture.context,
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
            context: fixture.context,
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
    var context: WebInspectorContext
    var divID: DOMNode.ID
    var inputID: DOMNode.ID
}

@MainActor
private func makeMenuFixture() throws -> DOMTreeMenuModelFixture {
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    context.seedDOMDocument(menuFixtureDocument())
    let divID = DOMNode.ID(DOM.Node.ID("div"))
    let inputID = DOMNode.ID(DOM.Node.ID("input"))
    _ = try #require(context.node(for: divID))
    _ = try #require(context.node(for: inputID))
    return DOMTreeMenuModelFixture(context: context, divID: divID, inputID: inputID)
}

private func menuFixtureDocument() -> DOM.Node {
    DOM.Node(
        id: .init("document"),
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: .init("html"),
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: .init("body"),
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        childNodeCount: 2,
                        children: [
                            DOM.Node(
                                id: .init("div"),
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                attributes: [
                                    "id": "start-of-content",
                                    "data-testid": "cellInnerDiv",
                                ],
                                attributeList: [
                                    DOM.Attribute(name: "id", value: "start-of-content"),
                                    DOM.Attribute(name: "data-testid", value: "cellInnerDiv"),
                                ]
                            ),
                            DOM.Node(
                                id: .init("input"),
                                nodeType: 1,
                                nodeName: "INPUT",
                                localName: "input",
                                attributes: ["disabled": ""],
                                attributeList: [DOM.Attribute(name: "disabled", value: "")]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}
#endif

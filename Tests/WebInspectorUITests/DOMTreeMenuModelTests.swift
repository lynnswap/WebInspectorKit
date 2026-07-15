#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
@testable import WebInspectorProxyKit
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
struct DOMTreeMenuModelTests {
    @Test
    func singleNodeSelectionEnablesTextAndNodeActions() async throws {
        let fixture = try await makeMenuFixture()
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
        await fixture.runtime.close()
    }

    @Test
    func singleNodeSelectionDisablesDeleteWhenHandlerIsMissing() async throws {
        let fixture = try await makeMenuFixture()
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
        #expect(!model.canCopySelectorPath)
        #expect(!model.canCopyXPath)
        #expect(!model.canDelete)
        await fixture.runtime.close()
    }

    @Test
    func multiNodeSelectionUsesSharedHTMLCopyAndMultiDeleteState() async throws {
        let fixture = try await makeMenuFixture()
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
        await fixture.runtime.close()
    }

    @Test
    func deleteSelectionClearsLocalSelectionOnlyAfterSuccessfulAction() async throws {
        let fixture = try await makeMenuFixture()
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
        await fixture.runtime.close()
    }
}

private struct DOMTreeMenuModelFixture {
    var runtime: WebInspectorDataKitTestRuntime
    var context: WebInspectorModelContext
    var divID: DOMNode.ID
    var inputID: DOMNode.ID
}

@MainActor
private func makeMenuFixture() async throws -> DOMTreeMenuModelFixture {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom]),
            document: menuFixtureDocument()
        )
    )
    let context = runtime.container.mainContext
    let nodes = try await context.fetch(
        WebInspectorFetchDescriptor<DOMNode>()
    )
    let divID = try #require(nodes.first(where: { $0.localName == "div" })?.id)
    let inputID = try #require(nodes.first(where: { $0.localName == "input" })?.id)
    return DOMTreeMenuModelFixture(
        runtime: runtime,
        context: context,
        divID: divID,
        inputID: inputID
    )
}

private func menuFixtureDocument() -> WebInspectorDataKitTestRuntime.Document {
    WebInspectorDataKitTestRuntime.Document(
        children: [
            .element(
                id: "html",
                name: "html",
                children: [
                    .element(
                        id: "body",
                        name: "body",
                        children: [
                            .element(
                                id: "div",
                                name: "div",
                                attributes: [
                                    "id": "start-of-content",
                                    "data-testid": "cellInnerDiv",
                                ]
                            ),
                            .element(
                                id: "input",
                                name: "input",
                                attributes: ["disabled": ""]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}
#endif

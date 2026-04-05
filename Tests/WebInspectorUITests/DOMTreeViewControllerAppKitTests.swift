#if canImport(AppKit)
import AppKit
import Testing
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMTreeViewControllerAppKitTests {
    @Test
    func contextMenuDeletePrefersCapturedIdentityOverLiveBackendLookup() async throws {
        let inspector = makeInspector(
            children: [makeNode(localID: 42, backendNodeID: 42)]
        )
        let viewController = WIDOMTreeViewController(inspector: inspector)
        var deletedNodeIDs: [Int] = []
        inspector.session.testRemoveNodeOverride = { nodeId, _, _ in
            deletedNodeIDs.append(nodeId)
            return .applied(())
        }
        let capturedNodeIdentity = try #require(inspector.document.node(backendNodeID: 42)?.id)

        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 77, backendNodeID: 42)]
                )
            )
        )

        let result = await viewController.invokeContextMenuDeleteForTesting(
            nodeID: 42,
            nodeIdentity: capturedNodeIdentity
        )

        #expect(result == .ignoredStaleContext)
        #expect(deletedNodeIDs.isEmpty)
    }

    @Test
    func contextMenuDeleteFallsBackToLiveLookupWhenCapturedIdentityIsUnavailable() async {
        let inspector = makeInspector(
            children: [makeNode(localID: 77, backendNodeID: 42)]
        )
        let viewController = WIDOMTreeViewController(inspector: inspector)
        var deletedNodeIDs: [Int] = []
        inspector.session.testRemoveNodeOverride = { nodeId, _, _ in
            deletedNodeIDs.append(nodeId)
            return .applied(())
        }

        let result = await viewController.invokeContextMenuDeleteForTesting(
            nodeID: 42,
            nodeIdentity: nil
        )

        #expect(result == .applied)
        #expect(deletedNodeIDs == [42])
    }

    @Test
    func contextMenuDeleteDoesNotGuessRawNodeIDWhenLiveLookupIsUnavailable() async {
        let inspector = makeInspector(children: [])
        let viewController = WIDOMTreeViewController(inspector: inspector)
        var deletedNodeIDs: [Int] = []
        inspector.session.testRemoveNodeOverride = { nodeId, _, _ in
            deletedNodeIDs.append(nodeId)
            return .applied(())
        }

        let result = await viewController.invokeContextMenuDeleteForTesting(
            nodeID: 42,
            nodeIdentity: nil
        )

        #expect(result == .failed)
        #expect(deletedNodeIDs.isEmpty)
    }

    @Test
    func deleteNodePrefersLocalIDResolutionBeforeBackendNodeID() async {
        let inspector = makeInspector(
            children: [
                makeNode(localID: 42, backendNodeID: 77),
                makeNode(localID: 77, backendNodeID: 42),
            ]
        )
        var deletedNodeIDs: [Int] = []
        inspector.session.testRemoveNodeOverride = { nodeId, _, _ in
            deletedNodeIDs.append(nodeId)
            return .applied(())
        }

        let result = await inspector.deleteNode(nodeId: 42, undoManager: nil)

        #expect(result == .applied)
        #expect(deletedNodeIDs == [42])
    }

    @Test
    func copyNodeFallsBackToLiveBackendLookupWhenLocalHandleIsUnavailable() async throws {
        let inspector = makeInspector(
            children: [makeNode(localID: 77, backendNodeID: 42)]
        )
        var copiedNodeIDs: [Int] = []
        inspector.session.testSelectionCopyTextOverride = { nodeId, _ in
            copiedNodeIDs.append(nodeId)
            return "copied"
        }

        let text = try await inspector.copyNode(nodeId: 42, kind: .html)

        #expect(text == "copied")
        #expect(copiedNodeIDs == [77])
    }

    @Test
    func copyNodeDoesNotGuessRawNodeIDWhenLiveLookupIsUnavailable() async throws {
        let inspector = makeInspector(children: [])
        var copiedNodeIDs: [Int] = []
        inspector.session.testSelectionCopyTextOverride = { nodeId, _ in
            copiedNodeIDs.append(nodeId)
            return "copied"
        }

        let text = try await inspector.copyNode(nodeId: 42, kind: .html)

        #expect(text.isEmpty)
        #expect(copiedNodeIDs.isEmpty)
    }

    private func makeInspector(children: [DOMGraphNodeDescriptor]) -> WIDOMInspector {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: children)
            )
        )
        return inspector
    }

    private func makeNode(
        localID: UInt64,
        backendNodeID: Int? = nil,
        children: [DOMGraphNodeDescriptor] = []
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: backendNodeID ?? Int(localID),
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            nodeValue: "",
            attributes: [],
            childCount: children.count,
            layoutFlags: [],
            isRendered: true,
            children: children
        )
    }
}
#endif

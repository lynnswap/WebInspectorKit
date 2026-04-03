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

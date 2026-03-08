import Testing
import WebInspectorTransport
@testable import WebInspectorEngine

@MainActor
struct DOMTransportDriverTests {
    @Test
    func nodeDescriptorPreservesRenderedStateFromLayoutFlags() {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
        )

        let hiddenNode = makeNode(
            nodeId: 10,
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            children: [],
            layoutFlags: []
        )
        let renderedNode = makeNode(
            nodeId: 11,
            nodeType: 1,
            nodeName: "SPAN",
            localName: "span",
            children: [],
            layoutFlags: ["rendered"]
        )

        #expect(driver.testNodeDescriptor(from: hiddenNode).isRendered == false)
        #expect(driver.testNodeDescriptor(from: renderedNode).isRendered == true)
    }

    @Test
    func xpathSkipsSyntheticDocumentRoot() {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
        )

        let div = makeNode(
            nodeId: 4,
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            children: []
        )
        let body = makeNode(
            nodeId: 3,
            nodeType: 1,
            nodeName: "BODY",
            localName: "body",
            children: [div]
        )
        let html = makeNode(
            nodeId: 2,
            nodeType: 1,
            nodeName: "HTML",
            localName: "html",
            children: [body]
        )
        let document = makeNode(
            nodeId: 1,
            nodeType: 9,
            nodeName: "#document",
            localName: "",
            children: [html],
            layoutFlags: ["rendered"]
        )

        #expect(driver.testXPath(for: [document, html, body, div]) == "/html/body/div")
    }

    @Test
    func preserveStateReloadAdvancesDocumentGeneration() {
        let graphStore = DOMGraphStore()
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: graphStore
        )
        let body = makeNode(
            nodeId: 3,
            nodeType: 1,
            nodeName: "BODY",
            localName: "body",
            children: []
        )
        let html = makeNode(
            nodeId: 2,
            nodeType: 1,
            nodeName: "HTML",
            localName: "html",
            children: [body]
        )
        let document = makeNode(
            nodeId: 1,
            nodeType: 9,
            nodeName: "#document",
            localName: "",
            children: [html],
            layoutFlags: ["rendered"]
        )

        driver.testApplyDocument(root: document, preserveState: false)
        graphStore.select(nodeID: 3)

        let generationAfterInitialLoad = graphStore.documentGeneration

        driver.testApplyDocument(root: document, preserveState: true)

        #expect(graphStore.documentGeneration == generationAfterInitialLoad + 1)
        #expect(graphStore.selectedEntry?.id.nodeID == 3)
        #expect(graphStore.selectedEntry?.id.documentGeneration == graphStore.documentGeneration)
    }

    @Test
    func hydrateUnknownChildrenSkipsLeafNodesThatExplicitlyReportZeroChildren() async throws {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
        )
        let leaf = makeNode(
            nodeId: 21,
            nodeType: 1,
            nodeName: "SPAN",
            localName: "span",
            children: []
        )

        let populated = try await driver.testPopulateChildren(
            for: leaf,
            depthRemaining: 2,
            allowUnknownChildren: true
        )

        #expect(populated.nodeId == 21)
        #expect(populated.children?.isEmpty == true)
    }
}

private func makeNode(
    nodeId: Int,
    nodeType: Int,
    nodeName: String,
    localName: String,
    children: [WITransportDOMNode],
    layoutFlags: [String] = []
) -> WITransportDOMNode {
    WITransportDOMNode(
        nodeId: nodeId,
        nodeType: nodeType,
        nodeName: nodeName,
        localName: localName,
        nodeValue: "",
        childNodeCount: children.count,
        children: children,
        attributes: [],
        documentURL: nil,
        baseURL: nil,
        frameId: nil,
        layoutFlags: layoutFlags
    )
}

import Testing
import WebKit
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
    func nodeDescriptorKeepsDocumentNodesRenderedWithoutLayoutFlags() {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
        )

        let documentNode = makeNode(
            nodeId: 1,
            nodeType: 9,
            nodeName: "#document",
            localName: "",
            children: []
        )

        #expect(driver.testNodeDescriptor(from: documentNode).isRendered == true)
    }

    @Test
    func nodeDescriptorInfersHiddenInlineStyleWithoutLayoutFlags() {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
        )

        let hiddenNode = WITransportDOMNode(
            nodeId: 21,
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            nodeValue: "",
            childNodeCount: 0,
            children: [],
            attributes: ["style", "display:none"],
            documentURL: nil,
            baseURL: nil,
            frameId: nil,
            layoutFlags: nil
        )

        #expect(driver.testNodeDescriptor(from: hiddenNode).isRendered == false)
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

    @Test
    func selectionModeUsesBridgeHelperOnMacAndStoresPendingSelectedNode() async throws {
        let bridge = StubDOMSelectionBridge(
            result: .init(cancelled: false, requiredDepth: 5),
            selectedNodePath: [0, 0]
        )
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore(),
            selectionBridge: bridge
        )
        let webView = WKWebView(frame: .zero)
        driver.webView = webView

        let result = try await driver.beginSelectionMode()

        #expect(result.cancelled == false)
        #expect(result.requiredDepth == 5)
        #expect(bridge.installCallCount == 1)
        #expect(bridge.beginSelectionCallCount == 1)
        #expect(bridge.resolvedDepths == [6])
        #expect(driver.testPendingSelectedNodeID == nil)
    }

    @Test
    func cancelSelectionModeUsesBridgeHelperAndClearsPendingSelectedNode() async {
        let bridge = StubDOMSelectionBridge(
            result: .init(cancelled: false, requiredDepth: 2),
            selectedNodePath: [0]
        )
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore(),
            selectionBridge: bridge
        )
        let webView = WKWebView(frame: .zero)
        driver.webView = webView

        _ = try? await driver.beginSelectionMode()
        await driver.cancelSelectionMode()

        #expect(bridge.cancelSelectionCallCount == 1)
        #expect(driver.testPendingSelectedNodeID == nil)
    }

    @Test
    func preserveStateReloadResolvesPendingSelectionPathAgainstTransportSnapshot() {
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

        driver.testSetPendingSelectedNodePath([0])
        driver.testApplyDocument(root: document, preserveState: true)

        #expect(graphStore.selectedEntry?.id.nodeID == 3)
    }

    @Test
    func pendingSelectionPathUsesHtmlAsItsRootWhenTransportSnapshotStartsAtDocument() {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
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

        driver.testSetPendingSelectedNodePath([])
        #expect(driver.testResolvedPendingSelectedNodeID(in: document) == 2)

        driver.testSetPendingSelectedNodePath([0])
        #expect(driver.testResolvedPendingSelectedNodeID(in: document) == 3)
    }

    @Test
    func clearingPendingSelectionDropsAnyBridgeDerivedSelectionPath() {
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

        driver.testSetPendingSelectedNodePath([0])
        driver.rememberPendingSelection(nodeId: nil)
        driver.testApplyDocument(root: document, preserveState: true)

        #expect(graphStore.selectedEntry == nil)
    }

    @Test
    func missingNodeStyleFetchReturnsEmptyMatchedStylesPayload() throws {
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore()
        )

        let inlineError = WITransportError.remoteError(
            scope: .page,
            method: "CSS.getInlineStylesForNode",
            message: "Missing node for given nodeId"
        )
        let matchedError = WITransportError.remoteError(
            scope: .page,
            method: "CSS.getMatchedStylesForNode",
            message: "Missing node for given nodeId"
        )

        let payload = try driver.testMakeMatchedStylesPayloadForFailures(
            nodeId: 42,
            maxRules: 0,
            inlineError: inlineError,
            matchedError: matchedError
        )

        #expect(payload.nodeId == 42)
        #expect(payload.rules.isEmpty)
        #expect(payload.truncated == false)
    }
}

@MainActor
private final class StubDOMSelectionBridge: DOMSelectionBridging {
    let result: DOMSelectionModeResult
    let selectedNodePath: [Int]?

    private(set) var installCallCount = 0
    private(set) var beginSelectionCallCount = 0
    private(set) var cancelSelectionCallCount = 0
    private(set) var resolvedDepths: [Int] = []

    init(result: DOMSelectionModeResult, selectedNodePath: [Int]?) {
        self.result = result
        self.selectedNodePath = selectedNodePath
    }

    func installIfNeeded(on webView: WKWebView) async throws {
        _ = webView
        installCallCount += 1
    }

    func beginSelection(on webView: WKWebView) async throws -> DOMSelectionModeResult {
        _ = webView
        beginSelectionCallCount += 1
        return result
    }

    func cancelSelection(on webView: WKWebView) async {
        _ = webView
        cancelSelectionCallCount += 1
    }

    func resolveSelectedNodePath(on webView: WKWebView, maxDepth: Int) async throws -> [Int]? {
        _ = webView
        resolvedDepths.append(maxDepth)
        return selectedNodePath
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

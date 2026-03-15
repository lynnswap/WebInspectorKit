#if DEBUG
import Foundation
import WebKit
import WebInspectorCore
import WebInspectorTransport
@_spi(PreviewSupport) import WebInspectorCore

@MainActor
enum WIDOMPreviewFixtures {
    enum Mode {
        case empty
        case selected
        case selectedEditableAttributes
    }

    static func makeRuntime() -> WIDOMRuntime {
        let graphStore = DOMGraphStore()
        return WIDOMRuntime(
            configuration: .init(),
            graphStore: graphStore,
            backend: PreviewDOMBackend(graphStore: graphStore)
        )
    }

    static func makeStore(mode: Mode) -> WIDOMStore {
        let runtime = makeRuntime()
        let frontendRuntime = WIDOMFrontendRuntime(session: runtime)
        let store = WIDOMStore(
            session: runtime,
            frontendBridge: frontendRuntime
        )
        applySampleTree(to: store)
        applySampleSelection(to: store, mode: mode)
        return store
    }

    static func applySampleSelection(to store: WIDOMStore, mode: Mode) {
        let graphStore = store.session.graphStore
        graphStore.applySelectionSnapshot(nil)

        switch mode {
        case .empty:
            break
        case .selected:
            let nodeID = 6
            let attributes = [
                DOMAttribute(nodeId: nodeID, name: "aria-label", value: "スノーボード"),
                DOMAttribute(nodeId: nodeID, name: "class", value: "hero-label"),
                DOMAttribute(nodeId: nodeID, name: "data-kind", value: "doodle")
            ]
            graphStore.applySelectionSnapshot(
                .init(
                    nodeID: nodeID,
                    preview: "<span aria-label=\"スノーボード\">...</span>",
                    attributes: attributes,
                    path: ["html", "body", "div", "span"],
                    selectorPath: "#hplogo > span",
                    styleRevision: 0
                )
            )
            let rules = [
                DOMStyleRule(
                    origin: .author,
                    selectorText: ".logo span[aria-label]",
                    declarations: [
                        DOMStyleDeclaration(name: "display", value: "inline-block", important: false),
                        DOMStyleDeclaration(name: "max-width", value: "100%", important: false)
                    ],
                    source: DOMStyleSource(label: "styles.css:120")
                )
            ]
            graphStore.applyStyle(
                .init(
                    nodeId: nodeID,
                    matched: DOMMatchedStyleState(
                        sections: [.init(kind: .element, relatedNodeId: nodeID, rules: rules)],
                        isTruncated: false,
                        blockedStylesheetCount: 0
                    ),
                    computed: DOMComputedStyleState(
                        properties: [
                            .init(name: "display", value: "inline-block", isImplicit: false),
                            .init(name: "max-width", value: "100%", isImplicit: false)
                        ]
                    )
                ),
                for: nodeID
            )
        case .selectedEditableAttributes:
            let nodeID = 8
            let attributes = [
                DOMAttribute(
                    nodeId: nodeID,
                    name: "style",
                    value: """
                    border:none;
                    max-width:100%;
                    margin:8px 0;
                    min-width:1px;
                    min-height:1px
                    """
                ),
                DOMAttribute(nodeId: nodeID, name: "alt", value: "スノーボード 2026"),
                DOMAttribute(
                    nodeId: nodeID,
                    name: "src",
                    value: "/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif"
                )
            ]
            graphStore.applySelectionSnapshot(
                .init(
                    nodeID: nodeID,
                    preview: "<img alt=\"スノーボード 2026\" src=\"/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif\">",
                    attributes: attributes,
                    path: ["html", "body", "div", "img"],
                    selectorPath: "#hplogo > img",
                    styleRevision: 0
                )
            )
            let rules = [
                DOMStyleRule(
                    origin: .author,
                    selectorText: ".logo img[alt]",
                    declarations: [
                        DOMStyleDeclaration(name: "display", value: "inline-block", important: false),
                        DOMStyleDeclaration(name: "max-width", value: "100%", important: false),
                        DOMStyleDeclaration(name: "height", value: "auto", important: false)
                    ],
                    source: DOMStyleSource(label: "styles.css:188")
                )
            ]
            graphStore.applyStyle(
                .init(
                    nodeId: nodeID,
                    matched: DOMMatchedStyleState(
                        sections: [.init(kind: .element, relatedNodeId: nodeID, rules: rules)],
                        isTruncated: false,
                        blockedStylesheetCount: 0
                    ),
                    computed: DOMComputedStyleState(
                        properties: [
                            .init(name: "display", value: "inline-block", isImplicit: false),
                            .init(name: "max-width", value: "100%", isImplicit: false),
                            .init(name: "height", value: "auto", isImplicit: false)
                        ]
                    )
                ),
                for: nodeID
            )
        }
    }

    @discardableResult
    static func bootstrapDOMTreeForPreview(_ store: WIDOMStore) -> WKWebView {
        let key = ObjectIdentifier(store)
        if let existingLoader = pageLoaderByInspector[key] {
            applySampleTree(to: store)
            return existingLoader.pageWebView
        }

        let loader = WIDOMPreviewPageLoader(store: store)
        pageLoaderByInspector[key] = loader
        applySampleTree(to: store)
        return loader.pageWebView
    }

    static func applySampleTree(to store: WIDOMStore) {
        let snapshot = DOMGraphSnapshot(
            root: DOMGraphNodeDescriptor(
                nodeID: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                nodeValue: "",
                attributes: [],
                childCount: 1,
                layoutFlags: [],
                isRendered: true,
                children: [
                    DOMGraphNodeDescriptor(
                        nodeID: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        nodeValue: "",
                        attributes: [DOMAttribute(nodeId: 2, name: "lang", value: "ja")],
                        childCount: 2,
                        layoutFlags: [],
                        isRendered: true,
                        children: [
                            DOMGraphNodeDescriptor(
                                nodeID: 3,
                                nodeType: 1,
                                nodeName: "HEAD",
                                localName: "head",
                                nodeValue: "",
                                attributes: [],
                                childCount: 0,
                                layoutFlags: [],
                                isRendered: true,
                                children: []
                            ),
                            DOMGraphNodeDescriptor(
                                nodeID: 4,
                                nodeType: 1,
                                nodeName: "BODY",
                                localName: "body",
                                nodeValue: "",
                                attributes: [DOMAttribute(nodeId: 4, name: "class", value: "preview")],
                                childCount: 2,
                                layoutFlags: [],
                                isRendered: true,
                                children: [
                                    DOMGraphNodeDescriptor(
                                        nodeID: 5,
                                        nodeType: 1,
                                        nodeName: "DIV",
                                        localName: "div",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(nodeId: 5, name: "id", value: "hplogo")],
                                        childCount: 2,
                                        layoutFlags: [],
                                        isRendered: true,
                                        children: [
                                            DOMGraphNodeDescriptor(
                                                nodeID: 6,
                                                nodeType: 1,
                                                nodeName: "SPAN",
                                                localName: "span",
                                                nodeValue: "",
                                                attributes: [
                                                    DOMAttribute(nodeId: 6, name: "aria-label", value: "スノーボード"),
                                                    DOMAttribute(nodeId: 6, name: "class", value: "hero-label"),
                                                    DOMAttribute(nodeId: 6, name: "data-kind", value: "doodle")
                                                ],
                                                childCount: 1,
                                                layoutFlags: [],
                                                isRendered: true,
                                                children: [
                                                    DOMGraphNodeDescriptor(
                                                        nodeID: 7,
                                                        nodeType: 3,
                                                        nodeName: "#text",
                                                        localName: "",
                                                        nodeValue: "WebInspector Preview",
                                                        attributes: [],
                                                        childCount: 0,
                                                        layoutFlags: [],
                                                        isRendered: true,
                                                        children: []
                                                    )
                                                ]
                                            ),
                                            DOMGraphNodeDescriptor(
                                                nodeID: 8,
                                                nodeType: 1,
                                                nodeName: "IMG",
                                                localName: "img",
                                                nodeValue: "",
                                                attributes: [
                                                    DOMAttribute(
                                                        nodeId: 8,
                                                        name: "style",
                                                        value: """
                                                        border:none;
                                                        max-width:100%;
                                                        margin:8px 0;
                                                        min-width:1px;
                                                        min-height:1px
                                                        """
                                                    ),
                                                    DOMAttribute(nodeId: 8, name: "alt", value: "スノーボード 2026"),
                                                    DOMAttribute(
                                                        nodeId: 8,
                                                        name: "src",
                                                        value: "/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif"
                                                    )
                                                ],
                                                childCount: 0,
                                                layoutFlags: [],
                                                isRendered: true,
                                                children: []
                                            )
                                        ]
                                    ),
                                    DOMGraphNodeDescriptor(
                                        nodeID: 9,
                                        nodeType: 1,
                                        nodeName: "SECTION",
                                        localName: "section",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(nodeId: 9, name: "class", value: "content")],
                                        childCount: 0,
                                        layoutFlags: [],
                                        isRendered: true,
                                        children: []
                                    )
                                ]
                            )
                        ]
                    )
                ]
            ),
            selectedNodeID: 6
        )

        store.session.graphStore.resetForDocumentUpdate()
        store.session.graphStore.applySnapshot(snapshot)
        store.session.graphStore.select(nodeID: snapshot.selectedNodeID)
        store.setExpandedEntryIDsForTesting([
            DOMEntryID(documentGeneration: store.session.graphStore.documentGeneration, nodeID: 1),
            DOMEntryID(documentGeneration: store.session.graphStore.documentGeneration, nodeID: 2),
            DOMEntryID(documentGeneration: store.session.graphStore.documentGeneration, nodeID: 4),
            DOMEntryID(documentGeneration: store.session.graphStore.documentGeneration, nodeID: 5),
        ])
    }

    private static var pageLoaderByInspector: [ObjectIdentifier: WIDOMPreviewPageLoader] = [:]
}

@MainActor
private final class WIDOMPreviewPageLoader: NSObject, WKNavigationDelegate {
    private let store: WIDOMStore
    private let webView: WKWebView

    var pageWebView: WKWebView {
        webView
    }

    init(store: WIDOMStore) {
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        store.wiAttachPreviewPageWebView(webView)
        webView.loadHTMLString(Self.sampleHTML, baseURL: URL(string: "https://preview.local"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak store] in
            guard let store else {
                return
            }
            await store.reloadFrontend(preserveState: true)
        }
    }

    private static let sampleHTML = """
    <!doctype html>
    <html lang="ja">
      <head>
        <meta charset="utf-8" />
        <title>DOM Preview</title>
      </head>
      <body class="preview">
        <div id="hplogo">
          <span aria-label="スノーボード" class="hero-label" data-kind="doodle">WebInspector Preview</span>
          <img
            style="border:none;max-width:100%;margin:8px 0;min-width:1px;min-height:1px"
            alt="スノーボード 2026"
            src="/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif"
          />
        </div>
        <section class="content"></section>
      </body>
    </html>
    """
}

@MainActor
private final class PreviewDOMBackend: WIDOMBackend {
    weak var eventSink: (any WIDOMProtocolEventSink)?
    private(set) weak var webView: WKWebView?

    let support = WIBackendSupport(
        availability: .supported,
        backendKind: .nativeInspectorIOS,
        capabilities: [.domDomain]
    )

    private let graphStore: DOMGraphStore

    init(graphStore: DOMGraphStore) {
        self.graphStore = graphStore
    }

    func updateConfiguration(_ configuration: DOMConfiguration) {
        _ = configuration
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView() {
        webView = nil
    }

    func setAutoSnapshot(enabled: Bool) async {
        _ = enabled
    }

    func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws {
        _ = preserveState
        _ = requestedDepth
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        _ = parentNodeId
        return []
    }

    func captureSnapshot(maxDepth: Int) async throws -> String {
        _ = maxDepth
        return "{}"
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        _ = nodeId
        _ = maxDepth
        return "{}"
    }

    func styles(nodeId: Int, maxMatchedRules: Int) async throws -> DOMNodeStylePayload {
        _ = maxMatchedRules
        guard let entry = graphStore.entry(forNodeID: nodeId) else {
            return .init(nodeId: nodeId, matched: .empty, computed: .empty)
        }
        return .init(
            nodeId: nodeId,
            matched: entry.style.matched,
            computed: entry.style.computed
        )
    }

    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        _ = maxDepth
        return [:]
    }

    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        _ = nodeId
        _ = maxDepth
        return [:]
    }

    func beginSelectionMode() async throws -> DOMSelectionModeResult {
        .init(cancelled: true, requiredDepth: 0)
    }

    func cancelSelectionMode() async {}

    func highlight(nodeId: Int) async {
        _ = nodeId
    }

    func hideHighlight() async {}

    func rememberPendingSelection(nodeId: Int?) {
        _ = nodeId
    }

    func removeNode(nodeId: Int) async {
        _ = nodeId
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        _ = nodeId
        return nil
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        _ = undoToken
        return false
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool {
        _ = undoToken
        _ = nodeId
        return false
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        _ = nodeId
        _ = name
        _ = value
    }

    func removeAttribute(nodeId: Int, name: String) async {
        _ = nodeId
        _ = name
    }

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        _ = kind
        return graphStore.entry(forNodeID: nodeId)?.preview ?? ""
    }
}
#endif

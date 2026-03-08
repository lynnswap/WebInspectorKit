#if DEBUG
import Foundation
import WebKit
import WebInspectorEngine
@_spi(PreviewSupport) import WebInspectorRuntime

@MainActor
enum WIDOMPreviewFixtures {
    enum Mode {
        case empty
        case selected
        case selectedEditableAttributes
    }

    static func makeInspector(mode: Mode) -> WIDOMModel {
        let inspector = WIDOMModel(session: DOMSession())
        applySampleTree(to: inspector)
        applySampleSelection(to: inspector, mode: mode)
        return inspector
    }

    static func applySampleSelection(to inspector: WIDOMModel, mode: Mode) {
        let graphStore = inspector.session.graphStore
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
                DOMMatchedStyleRule(
                    origin: .author,
                    selectorText: ".logo span[aria-label]",
                    declarations: [
                        DOMMatchedStyleDeclaration(name: "display", value: "inline-block", important: false),
                        DOMMatchedStyleDeclaration(name: "max-width", value: "100%", important: false)
                    ],
                    sourceLabel: "styles.css:120"
                )
            ]
            graphStore.applyMatchedStyles(
                .init(nodeId: nodeID, rules: rules, truncated: false, blockedStylesheetCount: 0),
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
                DOMMatchedStyleRule(
                    origin: .author,
                    selectorText: ".logo img[alt]",
                    declarations: [
                        DOMMatchedStyleDeclaration(name: "display", value: "inline-block", important: false),
                        DOMMatchedStyleDeclaration(name: "max-width", value: "100%", important: false),
                        DOMMatchedStyleDeclaration(name: "height", value: "auto", important: false)
                    ],
                    sourceLabel: "styles.css:188"
                )
            ]
            graphStore.applyMatchedStyles(
                .init(nodeId: nodeID, rules: rules, truncated: false, blockedStylesheetCount: 0),
                for: nodeID
            )
        }
    }

    @discardableResult
    static func bootstrapDOMTreeForPreview(_ inspector: WIDOMModel) -> WKWebView {
        let key = ObjectIdentifier(inspector)
        if let existingLoader = pageLoaderByInspector[key] {
            applySampleTree(to: inspector)
            return existingLoader.pageWebView
        }

        let loader = WIDOMPreviewPageLoader(inspector: inspector)
        pageLoaderByInspector[key] = loader
        applySampleTree(to: inspector)
        return loader.pageWebView
    }

    static func applySampleTree(to inspector: WIDOMModel) {
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

        inspector.session.graphStore.resetForDocumentUpdate()
        inspector.session.graphStore.applySnapshot(snapshot)
        inspector.session.graphStore.select(nodeID: snapshot.selectedNodeID)
        inspector.setExpandedEntryIDsForTesting([
            DOMEntryID(documentGeneration: inspector.session.graphStore.documentGeneration, nodeID: 1),
            DOMEntryID(documentGeneration: inspector.session.graphStore.documentGeneration, nodeID: 2),
            DOMEntryID(documentGeneration: inspector.session.graphStore.documentGeneration, nodeID: 4),
            DOMEntryID(documentGeneration: inspector.session.graphStore.documentGeneration, nodeID: 5),
        ])
    }

    private static var pageLoaderByInspector: [ObjectIdentifier: WIDOMPreviewPageLoader] = [:]
}

@MainActor
private final class WIDOMPreviewPageLoader: NSObject, WKNavigationDelegate {
    private let inspector: WIDOMModel
    private let webView: WKWebView

    var pageWebView: WKWebView {
        webView
    }

    init(inspector: WIDOMModel) {
        self.inspector = inspector
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        inspector.wiAttachPreviewPageWebView(webView)
        webView.loadHTMLString(Self.sampleHTML, baseURL: URL(string: "https://preview.local"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak inspector] in
            guard let inspector else {
                return
            }
            await inspector.reloadInspector(preserveState: true)
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
#endif

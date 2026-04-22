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

    static func makeInspector(mode: Mode) -> WIDOMInspector {
        let inspector = WIDOMInspector()
        applySampleTree(to: inspector)
        applySampleSelection(to: inspector, mode: mode)
        return inspector
    }

    static func applySampleSelection(to inspector: WIDOMInspector, mode: Mode) {
        let graphStore = inspector.document
        graphStore.applySelectionSnapshot(nil)

        switch mode {
        case .empty:
            break
        case .selected:
            let localID: UInt64 = 42
            let attributes = [
                DOMAttribute(nodeId: 42, name: "alt", value: "スノーボード 2026"),
                DOMAttribute(nodeId: 42, name: "id", value: "hplogo"),
                DOMAttribute(nodeId: 42, name: "src", value: "/logos/doodles/2026/snowboarding.gif")
            ]
            graphStore.applySelectionSnapshot(
                .init(
                    localID: localID,
                    preview: "<span aria-label=\"スノーボード\">...</span>",
                    attributes: attributes,
                    path: [],
                    selectorPath: "#hplogo > span",
                    styleRevision: 0
                )
            )
        case .selectedEditableAttributes:
            let localID: UInt64 = 101
            let attributes = [
                DOMAttribute(
                    nodeId: 101,
                    name: "style",
                    value: """
                    border:none;
                    max-width:100%;
                    margin:8px 0;
                    min-width:1px;
                    min-height:1px
                    """
                ),
                DOMAttribute(nodeId: 101, name: "alt", value: "スノーボード 2026"),
                DOMAttribute(
                    nodeId: 101,
                    name: "src",
                    value: "/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif"
                )
            ]
            graphStore.applySelectionSnapshot(
                .init(
                    localID: localID,
                    preview: "<img alt=\"スノーボード 2026\" src=\"/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif\">",
                    attributes: attributes,
                    path: [],
                    selectorPath: "#hplogo > img",
                    styleRevision: 0
                )
            )
        }
    }

    @discardableResult
    static func bootstrapDOMTreeForPreview(_ inspector: WIDOMInspector) -> WKWebView {
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

    static func applySampleTree(to inspector: WIDOMInspector) {
        inspector.document.replaceDocument(with: sampleSnapshot(), isFreshDocument: true)
    }

    private static var pageLoaderByInspector: [ObjectIdentifier: WIDOMPreviewPageLoader] = [:]
    private static func sampleSnapshot() -> DOMGraphSnapshot {
        DOMGraphSnapshot(
            root: .init(
                localID: 1,
                backendNodeID: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                nodeValue: "",
                attributes: [],
                childCount: 1,
                layoutFlags: [],
                isRendered: true,
                children: [
                    .init(
                        localID: 2,
                        backendNodeID: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        nodeValue: "",
                        attributes: [DOMAttribute(name: "lang", value: "ja")],
                        childCount: 2,
                        layoutFlags: [],
                        isRendered: true,
                        children: [
                            .init(
                                localID: 3,
                                backendNodeID: 3,
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
                            .init(
                                localID: 4,
                                backendNodeID: 4,
                                nodeType: 1,
                                nodeName: "BODY",
                                localName: "body",
                                nodeValue: "",
                                attributes: [DOMAttribute(name: "class", value: "preview")],
                                childCount: 2,
                                layoutFlags: [],
                                isRendered: true,
                                children: [
                                    .init(
                                        localID: 5,
                                        backendNodeID: 5,
                                        nodeType: 1,
                                        nodeName: "DIV",
                                        localName: "div",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(name: "id", value: "preview-root")],
                                        childCount: 1,
                                        layoutFlags: [],
                                        isRendered: true,
                                        children: [
                                            .init(
                                                localID: 6,
                                                backendNodeID: 6,
                                                nodeType: 1,
                                                nodeName: "SPAN",
                                                localName: "span",
                                                nodeValue: "",
                                                attributes: [DOMAttribute(name: "aria-label", value: "スノーボード")],
                                                childCount: 1,
                                                layoutFlags: [],
                                                isRendered: true,
                                                children: [
                                                    .init(
                                                        localID: 7,
                                                        backendNodeID: 7,
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
                                            )
                                        ]
                                    ),
                                    .init(
                                        localID: 8,
                                        backendNodeID: 8,
                                        nodeType: 1,
                                        nodeName: "SECTION",
                                        localName: "section",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(name: "class", value: "content")],
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
            selectedLocalID: 6
        )
    }

    private static let sampleSnapshotBundle: NSDictionary = [
        "version": 1,
        "kind": "snapshot",
        "snapshot": [
            "root": [
                "nodeId": 1,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "childNodeCount": 1,
                "children": [
                    [
                        "nodeId": 2,
                        "nodeType": 1,
                        "nodeName": "HTML",
                        "localName": "html",
                        "nodeValue": "",
                        "childNodeCount": 2,
                        "attributes": ["lang", "ja"],
                        "children": [
                            [
                                "nodeId": 3,
                                "nodeType": 1,
                                "nodeName": "HEAD",
                                "localName": "head",
                                "nodeValue": "",
                                "childNodeCount": 0,
                            ],
                            [
                                "nodeId": 4,
                                "nodeType": 1,
                                "nodeName": "BODY",
                                "localName": "body",
                                "nodeValue": "",
                                "childNodeCount": 2,
                                "attributes": ["class", "preview"],
                                "children": [
                                    [
                                        "nodeId": 5,
                                        "nodeType": 1,
                                        "nodeName": "DIV",
                                        "localName": "div",
                                        "nodeValue": "",
                                        "childNodeCount": 1,
                                        "attributes": ["id", "preview-root"],
                                        "children": [
                                            [
                                                "nodeId": 6,
                                                "nodeType": 1,
                                                "nodeName": "SPAN",
                                                "localName": "span",
                                                "nodeValue": "",
                                                "childNodeCount": 1,
                                                "attributes": ["aria-label", "スノーボード"],
                                                "children": [
                                                    [
                                                        "nodeId": 7,
                                                        "nodeType": 3,
                                                        "nodeName": "#text",
                                                        "localName": "",
                                                        "nodeValue": "WebInspector Preview",
                                                        "childNodeCount": 0,
                                                    ],
                                                ],
                                            ],
                                        ],
                                    ],
                                    [
                                        "nodeId": 8,
                                        "nodeType": 1,
                                        "nodeName": "SECTION",
                                        "localName": "section",
                                        "nodeValue": "",
                                        "childNodeCount": 0,
                                        "attributes": ["class", "content"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            "selectedNodeId": 6,
            "selectedNodePath": [0, 1, 0, 0],
        ],
    ]
}

@MainActor
private final class WIDOMPreviewPageLoader: NSObject, WKNavigationDelegate {
    private let inspector: WIDOMInspector
    private let webView: WKWebView
    var pageWebView: WKWebView {
        webView
    }

    init(inspector: WIDOMInspector) {
        self.inspector = inspector
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        Task.immediateIfAvailable { [inspector, weak webView] in
            guard let webView else {
                return
            }
            await inspector.wiAttachPreviewPageWebView(webView)
            webView.loadHTMLString(Self.sampleHTML, baseURL: URL(string: "https://preview.local"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak inspector] in
            guard let inspector else {
                return
            }
            try? await inspector.reloadDocumentThrowing()
        }
    }

    private static let sampleHTML = """
    <!doctype html>
    <html lang="ja">
      <head>
        <meta charset="utf-8" />
        <title>DOM Preview</title>
      </head>
      <body>
        <main id="preview-root">
          <header class="hero"><h1>WebInspector Preview</h1></header>
          <section class="content">
            <article data-kind="sample">sample node</article>
          </section>
        </main>
      </body>
    </html>
    """
}

#endif

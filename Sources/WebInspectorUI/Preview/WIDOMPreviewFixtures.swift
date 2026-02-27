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
        inspector.selection.nodeId = nil
        inspector.selection.preview = ""
        inspector.selection.selectorPath = ""
        inspector.selection.attributes = []
        inspector.selection.matchedStyles = []
        inspector.selection.matchedStylesTruncated = false
        inspector.selection.blockedStylesheetCount = 0

        switch mode {
        case .empty:
            break
        case .selected:
            inspector.selection.nodeId = 42
            inspector.selection.preview = "<span aria-label=\"スノーボード\">...</span>"
            inspector.selection.selectorPath = "#hplogo > span"
            inspector.selection.attributes = [
                DOMAttribute(nodeId: 42, name: "alt", value: "スノーボード 2026"),
                DOMAttribute(nodeId: 42, name: "id", value: "hplogo"),
                DOMAttribute(nodeId: 42, name: "src", value: "/logos/doodles/2026/snowboarding.gif")
            ]
            inspector.selection.matchedStyles = [
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
        case .selectedEditableAttributes:
            inspector.selection.nodeId = 101
            inspector.selection.preview = "<img alt=\"スノーボード 2026\" src=\"/logos/doodles/2026/snowboarding-2026-feb-18-a-6753651837111226-law.gif\">"
            inspector.selection.selectorPath = "#hplogo > img"
            inspector.selection.attributes = [
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
            inspector.selection.matchedStyles = [
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
        guard
            let data = try? JSONSerialization.data(withJSONObject: sampleSnapshotBundle, options: []),
            let bundle = String(data: data, encoding: .utf8)
        else {
            return
        }
        inspector.enqueueMutationBundle(bundle, preserveState: true)
    }

    private static var pageLoaderByInspector: [ObjectIdentifier: WIDOMPreviewPageLoader] = [:]
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

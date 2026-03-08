import Testing
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorTransport

@MainActor
struct DOMLegacyPageDriverTests {
    @Test
    func unsupportedTransportSnapshotUsesLegacyDriverAndLoadsDocument() async throws {
        let session = DOMSession(
            configuration: .init(snapshotDepth: 3, subtreeDepth: 2),
            graphStore: DOMGraphStore(),
            defaultTransportSupportSnapshot: unsupportedTransportSnapshot()
        )
        let (webView, controller) = makeTestWebView()

        session.attach(to: webView)
        await loadHTML(
            """
            <html>
                <body>
                    <main id="content">
                        <section id="child">Hello</section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )

        try await session.reloadDocument(preserveState: false)
        let snapshot = try await session.captureSnapshot(maxDepth: 4)
        let contentNodeID = try #require(findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "content"))
        let childNodes = try await session.requestChildNodes(parentNodeId: contentNodeID)

        #expect(session.transportSupportSnapshot?.isSupported == false)
        #expect(session.transportCapabilities.isEmpty)
        #expect(session.graphStore.rootID != nil)
        #expect(controller.userScripts.count == 2)
        #expect(childNodes.contains { descriptor in
            descriptor.attributes.contains { $0.name == "id" && $0.value == "child" }
        })
    }

    @Test
    func mutationBundleUpdatesGraphStoreAndForwardsProtocolEvents() {
        let graphStore = DOMGraphStore()
        let driver = DOMLegacyPageDriver(configuration: .init(), graphStore: graphStore)
        let eventSink = RecordingDOMProtocolEventSink()
        driver.eventSink = eventSink

        driver.testHandleBundlePayload([
            "version": 1,
            "kind": "snapshot",
            "reason": "initial",
            "snapshot": [
                "root": [
                    "nodeId": 1,
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "nodeValue": "",
                    "attributes": [],
                    "children": [],
                ],
            ],
        ])

        driver.testHandleBundlePayload([
            "version": 1,
            "kind": "mutation",
            "events": [
                [
                    "method": "DOM.setChildNodes",
                    "params": [
                        "parentNodeId": 1,
                        "nodes": [
                            [
                                "nodeId": 2,
                                "nodeType": 1,
                                "nodeName": "SPAN",
                                "localName": "span",
                                "nodeValue": "",
                                "attributes": ["id", "child"],
                                "children": [],
                            ],
                        ],
                    ],
                ],
                [
                    "method": "DOM.attributeModified",
                    "params": [
                        "nodeId": 2,
                        "name": "class",
                        "value": "updated",
                    ],
                ],
            ],
        ])

        #expect(graphStore.entry(forNodeID: 2)?.attributes.contains { $0.name == "class" && $0.value == "updated" } == true)
        #expect(eventSink.events.map(\.method) == ["DOM.setChildNodes", "DOM.attributeModified"])
    }

    @Test
    func serializedEnvelopeMergesFallbackTreeForSelectionRecovery() {
        let normalizer = DOMLegacyBundleNormalizer()

        let snapshot = normalizer.normalizeSnapshotPayload([
            "type": "serialized-node-envelope",
            "node": [
                "nodeId": 1,
                "nodeType": 1,
                "nodeName": "DIV",
                "localName": "div",
                "children": [
                    [
                        "nodeId": 2,
                        "nodeType": 1,
                        "nodeName": "SPAN",
                        "localName": "span",
                    ],
                ],
            ],
            "fallback": [
                "root": [
                    "nodeId": 1,
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "children": [
                        [
                            "nodeId": 2,
                            "nodeType": 1,
                            "nodeName": "SPAN",
                            "localName": "span",
                            "children": [
                                [
                                    "nodeId": 3,
                                    "nodeType": 3,
                                    "nodeName": "#text",
                                    "localName": "",
                                    "nodeValue": "deep",
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                "selectedNodePath": [0, 0],
            ],
        ])

        #expect(snapshot?.root.children.first?.children.first?.nodeID == 3)
        #expect(snapshot?.selectedNodeID == 3)
    }

    @Test
    func macOSRemoteTransportWithoutFrontendHostingStillUsesTransportDriver() {
        let session = DOMSession(
            configuration: .init(),
            graphStore: DOMGraphStore(),
            defaultTransportSupportSnapshot: .init(
                availability: .supported,
                backendKind: .macOSRemoteInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain],
                failureReason: "frontend host unavailable"
            )
        )

        #expect(session.testPageAgentTypeName() == "DOMTransportDriver")
    }
}

@MainActor
private final class RecordingDOMProtocolEventSink: DOMProtocolEventSink {
    struct Event {
        let method: String
        let paramsData: Data
    }

    private(set) var events: [Event] = []

    func domDidReceiveProtocolEvent(method: String, paramsData: Data) {
        events.append(.init(method: method, paramsData: paramsData))
    }
}

@MainActor
private final class RecordingDOMUserContentController: WKUserContentController {
    private(set) var addedHandlers: [(name: String, world: WKContentWorld)] = []
    private(set) var removedHandlers: [(name: String, world: WKContentWorld)] = []

    override func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld: WKContentWorld, name: String) {
        addedHandlers.append((name, contentWorld))
        super.add(scriptMessageHandler, contentWorld: contentWorld, name: name)
    }

    override func removeScriptMessageHandler(forName name: String, contentWorld: WKContentWorld) {
        removedHandlers.append((name, contentWorld))
        super.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
    }
}

@MainActor
private func makeTestWebView() -> (WKWebView, RecordingDOMUserContentController) {
    let controller = RecordingDOMUserContentController()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController = controller
    let webView = WKWebView(frame: .zero, configuration: configuration)
    return (webView, controller)
}

@MainActor
private func loadHTML(_ html: String, in webView: WKWebView) async {
    let navigationDelegate = DOMLegacyNavigationDelegate()
    webView.navigationDelegate = navigationDelegate

    await withCheckedContinuation { continuation in
        navigationDelegate.continuation = continuation
        webView.loadHTMLString(html, baseURL: nil)
    }
}

@MainActor
private final class DOMLegacyNavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _ = webView
        _ = navigation
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        _ = webView
        _ = navigation
        _ = error
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        _ = webView
        _ = navigation
        _ = error
        continuation?.resume()
        continuation = nil
    }
}

private func findNodeId(
    inSnapshotJSON snapshotJSON: String,
    attributeName: String,
    attributeValue: String
) -> Int? {
    guard
        let data = snapshotJSON.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let root = object["root"] as? [String: Any]
    else {
        return nil
    }
    return findNodeId(inNode: root, attributeName: attributeName, attributeValue: attributeValue)
}

private func findNodeId(
    inNode node: [String: Any],
    attributeName: String,
    attributeValue: String
) -> Int? {
    if let attributes = node["attributes"] as? [String] {
        var index = 0
        while index + 1 < attributes.count {
            if attributes[index] == attributeName, attributes[index + 1] == attributeValue {
                return node["nodeId"] as? Int
            }
            index += 2
        }
    }

    if let children = node["children"] as? [[String: Any]] {
        for child in children {
            if let nodeId = findNodeId(inNode: child, attributeName: attributeName, attributeValue: attributeValue) {
                return nodeId
            }
        }
    }
    return nil
}

private func unsupportedTransportSnapshot() -> WITransportSupportSnapshot {
    WITransportSupportSnapshot(
        availability: .unsupported,
        backendKind: .unsupported,
        capabilities: [],
        failureReason: "unsupported for test"
    )
}

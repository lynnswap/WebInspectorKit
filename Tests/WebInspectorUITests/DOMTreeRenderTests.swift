#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMTreeRenderTests {
    @Test
    func treeViewHidesDocumentRowAndRendersDoctype() async throws {
        let inspector = WIDOMInspector()
        let (viewController, window) = makeHostedTreeViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let ready = await waitUntilAsync {
            await viewController.frontendIsReadyForTesting()
        }
        #expect(ready)

        inspector.inspectorBridge.updateBootstrap(makeBootstrapPayload(contextID: 1))
        await inspector.inspectorBridge.applyFullSnapshot(
            makeDocumentPayload(includeDoctype: true, includeOverlay: false),
            contextID: 1
        )

        let rendered = await waitUntilAsync {
            guard let text = await viewController.treeTextContentForTesting() else {
                return false
            }
            return text.contains("html")
        }
        #expect(rendered)

        let treeText = await viewController.treeTextContentForTesting() ?? ""
        #expect(!treeText.contains("#document"))
        #expect(treeText.localizedCaseInsensitiveContains("<!DOCTYPE html>"))
        #expect(treeText.localizedCaseInsensitiveContains("html"))

    }

    @Test
    func treeViewDropsOverlayNodesFromRenderedOutput() async throws {
        let inspector = WIDOMInspector()
        let (viewController, window) = makeHostedTreeViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let ready = await waitUntilAsync {
            await viewController.frontendIsReadyForTesting()
        }
        #expect(ready)

        inspector.inspectorBridge.updateBootstrap(makeBootstrapPayload(contextID: 1))
        await inspector.inspectorBridge.applyFullSnapshot(
            makeDocumentPayload(includeDoctype: false, includeOverlay: true),
            contextID: 1
        )

        let rendered = await waitUntilAsync {
            guard let text = await viewController.treeTextContentForTesting() else {
                return false
            }
            return text.contains("<body")
        }
        #expect(rendered)

        let treeText = await viewController.treeTextContentForTesting() ?? ""
        #expect(!treeText.contains("data-web-inspector-overlay"))
        #expect(!treeText.contains("overlay"))
        #expect(treeText.contains("<body"))
    }

    @Test
    func treeAndDetailReflectTheSameSelectedNode() async throws {
        let inspector = WIDOMInspector()
        let snapshot = makeGraphSnapshot()
        inspector.document.replaceDocument(with: snapshot, isFreshDocument: true)
        inspector.document.applySelectionSnapshot(
            .init(
                localID: 4,
                preview: "<body>",
                attributes: [DOMAttribute(nodeId: 4, name: "class", value: "page")],
                path: ["html", "body", "main"],
                selectorPath: "body.page",
                styleRevision: 0
            )
        )

        let (treeViewController, treeWindow) = makeHostedTreeViewController(inspector: inspector)
        defer { tearDown(window: treeWindow) }
        let (detailViewController, detailWindow) = makeHostedDetailViewController(inspector: inspector)
        defer { tearDown(window: detailWindow) }

        let treeReady = await waitUntilAsync {
            await treeViewController.frontendIsReadyForTesting()
        }
        #expect(treeReady)

        inspector.inspectorBridge.updateBootstrap(makeBootstrapPayload(contextID: 1))
        await inspector.inspectorBridge.applyFullSnapshot(
            makeDocumentPayload(includeDoctype: false, includeOverlay: false),
            contextID: 1
        )
        let selectedNode = try #require(inspector.document.selectedNode)
        await inspector.inspectorBridge.applySelectionPayload(
            makeSelectionPayload(
                localID: Int(selectedNode.localID),
                preview: "<body>",
                selectorPath: "body.page",
                attributes: [["name": "class", "value": "page"]]
            ),
            contextID: 1
        )

        let treeSelected = await waitUntilAsync {
            await treeViewController.selectedNodeIDForTesting() == 4
        }
        #expect(treeSelected)

        let detailReady = await waitUntil {
            guard let collectionView = detailViewController.collectionView else {
                return false
            }
            return visibleListCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "<body>"
        }
        #expect(detailReady)

        let selectedTreeText = await treeViewController.selectedNodeTextForTesting() ?? ""
        let detailPreview = visibleListCellText(
            in: try #require(detailViewController.collectionView),
            at: IndexPath(item: 0, section: 0)
        ) ?? ""

        #expect(selectedTreeText.localizedCaseInsensitiveContains("body"))
        #expect(detailPreview == "<body>")
    }

    @Test
    func selectedRowBackgroundReachesViewportTrailingEdgeAfterHorizontalScroll() async throws {
        let inspector = WIDOMInspector()
        let (viewController, window) = makeHostedTreeViewController(inspector: inspector)
        defer { tearDown(window: window) }

        let ready = await waitUntilAsync {
            await viewController.frontendIsReadyForTesting()
        }
        #expect(ready)

        inspector.inspectorBridge.updateBootstrap(makeBootstrapPayload(contextID: 1))
        await inspector.inspectorBridge.applyFullSnapshot(
            makeScrollableDocumentPayload(
                nodeCount: 8,
                wideNodeID: 108
            ),
            contextID: 1
        )

        let rendered = await waitUntilAsync {
            guard let text = await viewController.treeTextContentForTesting() else {
                return false
            }
            return text.contains("node-8")
        }
        #expect(rendered)

        await inspector.inspectorBridge.applySelectionPayload(["id": 108], contextID: 1)
        let selected = await waitUntilAsync {
            await viewController.selectedNodeIDForTesting() == 108
        }
        #expect(selected)

        let scrolled = await viewController.setTreeScrollPositionForTesting(left: 180)
        #expect(scrolled)

        let reachesViewportEdge = await waitUntilAsync {
            await viewController.selectedNodeReachesViewportRightEdgeForTesting() == true
        }
        #expect(reachesViewportEdge)
    }

}

@MainActor
private extension DOMTreeRenderTests {
    func makeHostedTreeViewController(
        inspector: WIDOMInspector
    ) -> (WIDOMTreeViewController, UIWindow) {
        let viewController = WIDOMTreeViewController(inspector: inspector)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        return (viewController, window)
    }

    func makeHostedDetailViewController(
        inspector: WIDOMInspector
    ) -> (WIDOMDetailViewController, UIWindow) {
        let viewController = WIDOMDetailViewController(inspector: inspector)
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        viewController.collectionView?.layoutIfNeeded()
        return (viewController, window)
    }

    func tearDown(window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    func makeBootstrapPayload(contextID: UInt64) -> [String: Any] {
        [
            "config": [
                "snapshotDepth": 4,
                "subtreeDepth": 3,
                "autoUpdateDebounce": 0.6,
            ],
            "context": [
                "contextID": contextID,
            ],
        ]
    }

    func makeDocumentPayload(
        includeDoctype: Bool,
        includeOverlay: Bool
    ) -> [String: Any] {
        var documentChildren: [[String: Any]] = []
        if includeDoctype {
            documentChildren.append([
                "nodeId": 9,
                "nodeType": 10,
                "nodeName": "html",
                "localName": "",
                "nodeValue": "",
                "childNodeCount": 0,
                "children": [],
            ])
        }

        var bodyChildren: [[String: Any]] = []
        if includeOverlay {
            bodyChildren.append([
                "nodeId": 7,
                "nodeType": 1,
                "nodeName": "DIV",
                "localName": "div",
                "nodeValue": "",
                "attributes": ["data-web-inspector-overlay", "true"],
                "childNodeCount": 0,
                "children": [],
            ])
        }
        bodyChildren.append([
            "nodeId": 6,
            "nodeType": 1,
            "nodeName": "MAIN",
            "localName": "main",
            "nodeValue": "",
            "attributes": ["id", "target"],
            "childNodeCount": 0,
            "children": [],
        ])

        documentChildren.append([
            "nodeId": 2,
            "nodeType": 1,
            "nodeName": "HTML",
            "localName": "html",
            "nodeValue": "",
            "attributes": ["lang", "en"],
            "childNodeCount": 2,
            "children": [
                [
                    "nodeId": 3,
                    "nodeType": 1,
                    "nodeName": "HEAD",
                    "localName": "head",
                    "nodeValue": "",
                    "childNodeCount": 0,
                    "children": [],
                ],
                [
                    "nodeId": 4,
                    "nodeType": 1,
                    "nodeName": "BODY",
                    "localName": "body",
                    "nodeValue": "",
                    "childNodeCount": bodyChildren.count,
                    "children": bodyChildren,
                ],
            ],
        ])

        return [
            "root": [
                "nodeId": 1,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "childNodeCount": documentChildren.count,
                "children": documentChildren,
            ],
        ]
    }

    func makeScrollableDocumentPayload(
        nodeCount: Int,
        wideNodeID: Int?
    ) -> [String: Any] {
        let bodyChildren: [[String: Any]] = (0..<nodeCount).map { index in
            let nodeID = 101 + index
            let attributes: [String]
            if nodeID == wideNodeID {
                attributes = [
                    "class",
                    "node-\(index + 1) viewport-width-selection-background-check " + String(repeating: "wide-token-", count: 18),
                ]
            } else {
                attributes = [
                    "class",
                    "node-\(index + 1)",
                ]
            }
            return [
                "nodeId": nodeID,
                "nodeType": 1,
                "nodeName": "DIV",
                "localName": "div",
                "nodeValue": "",
                "attributes": attributes,
                "childNodeCount": 0,
                "children": [],
            ]
        }

        return [
            "root": [
                "nodeId": 1,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "documentURL": "https://example.com/scrollable",
                "childNodeCount": 1,
                "children": [[
                    "nodeId": 2,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 3,
                        "nodeType": 1,
                        "nodeName": "BODY",
                        "localName": "body",
                        "nodeValue": "",
                        "childNodeCount": bodyChildren.count,
                        "children": bodyChildren,
                    ]],
                ]],
            ],
        ]
    }

    func makeGraphSnapshot() -> DOMGraphSnapshot {
        .init(
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
                        attributes: [DOMAttribute(name: "lang", value: "en")],
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
                                attributes: [DOMAttribute(name: "class", value: "page")],
                                childCount: 1,
                                layoutFlags: [],
                                isRendered: true,
                                children: [
                                    .init(
                                        localID: 6,
                                        backendNodeID: 6,
                                        nodeType: 1,
                                        nodeName: "MAIN",
                                        localName: "main",
                                        nodeValue: "",
                                        attributes: [DOMAttribute(name: "id", value: "target")],
                                        childCount: 0,
                                        layoutFlags: [],
                                        isRendered: true,
                                        children: []
                                    )
                                ]
                            ),
                        ]
                    )
                ]
            ),
            selectedLocalID: 6
        )
    }

    func makeShallowDocumentPayload(bodyChildCount: Int) -> [String: Any] {
        [
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
                        "attributes": ["lang", "en"],
                        "childNodeCount": 2,
                        "children": [
                            [
                                "nodeId": 3,
                                "nodeType": 1,
                                "nodeName": "HEAD",
                                "localName": "head",
                                "nodeValue": "",
                                "childNodeCount": 0,
                                "children": [],
                            ],
                            [
                                "nodeId": 4,
                                "nodeType": 1,
                                "nodeName": "BODY",
                                "localName": "body",
                                "nodeValue": "",
                                "childNodeCount": bodyChildCount,
                                "children": [],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    func makeBodySubtreePayload(childCount: Int) -> [String: Any] {
        let children = (0..<childCount).map { index in
            [
                "nodeId": 200 + index,
                "nodeType": 1,
                "nodeName": "DIV",
                "localName": "div",
                "nodeValue": "",
                "attributes": ["id", "item-\(index)"],
                "childNodeCount": 0,
                "children": [],
            ]
        }

        return [
            "nodeId": 4,
            "nodeType": 1,
            "nodeName": "BODY",
            "localName": "body",
            "nodeValue": "",
            "childNodeCount": childCount,
            "children": children,
        ]
    }

    func makeSelectionPayload(
        localID: Int,
        preview: String,
        selectorPath: String,
        attributes: [[String: String]]
    ) -> [String: Any] {
        [
            "id": localID,
            "backendNodeId": localID,
            "backendNodeIdIsStable": true,
            "preview": preview,
            "attributes": attributes,
            "path": ["html", "body", preview],
            "selectorPath": selectorPath,
            "styleRevision": 0,
        ]
    }

    func visibleListCellText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return nil
        }
        return configuration.text
    }

    func waitUntil(maxTicks: Int = 1024, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    func waitUntilAsync(
        maxTicks: Int = 1024,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if await condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await condition()
    }
}
#endif

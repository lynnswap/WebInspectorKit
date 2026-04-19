import Foundation
import Testing
import WebKit
@_spi(Monocly) @testable import WebInspectorRuntime
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized)
struct WIDOMInspectorTests {
    @Test
    func sameWebViewReattachKeepsContextID() async {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let firstContextID = inspector.testCurrentContextID
        await inspector.attach(to: webView)

        #expect(inspector.testCurrentContextID == firstContextID)
        #expect(inspector.hasPageWebView)
    }

    @Test
    func switchingWebViewsAdvancesContextID() async throws {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let firstWebView = makeTestWebView()
        let secondWebView = makeTestWebView()

        await inspector.attach(to: firstWebView)
        let firstContextID = try #require(inspector.testCurrentContextID)

        await inspector.attach(to: secondWebView)
        let secondContextID = try #require(inspector.testCurrentContextID)

        #expect(secondContextID > firstContextID)
    }

    @Test
    func reloadDocumentWithoutPageThrowsPageUnavailable() async {
        let inspector = WIDOMInspector()

        await #expect(throws: DOMOperationError.pageUnavailable) {
            try await inspector.reloadDocument()
        }
    }

    @Test
    func suspendClearsAttachedPageWebView() async {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        #expect(inspector.hasPageWebView)

        await inspector.suspend()

        #expect(!inspector.hasPageWebView)
        #expect(inspector.testCurrentContextID == nil)
    }

    @Test
    func attachBootstrapsCurrentDocumentFromTransport() async {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: targetIdentifier == "page-B" ? "https://example.com/b" : "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)

        let becameReady = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(becameReady)
        #expect(inspector.testCurrentDocumentURL == "https://example.com/a")
    }

    @Test
    func targetCommitAdvancesContextIDAndReloadsDocument() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: targetIdentifier == "page-B" ? "https://example.com/b" : "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(initiallyReady)

        let firstContextID = try #require(inspector.testCurrentContextID)

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        let reloaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID != firstContextID
                && inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(reloaded)
    }

    @Test
    func documentUpdatedInvalidatesAndReloadsFreshDocument() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(initiallyReady)
        let firstContextID = try #require(inspector.testCurrentContextID)

        backend.pageResultProvider = { method, _, _ in
            guard method == WITransportMethod.DOM.getDocument else {
                return [:]
            }
            return makeDocumentResult(url: "https://example.com/updated")
        }
        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])

        let reloaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID != firstContextID
                && inspector.testCurrentDocumentURL == "https://example.com/updated"
        }
        #expect(reloaded)
    }

    @Test
    func readyFrontendReopenResyncsCurrentDocument() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.document.clearDocument(isFreshDocument: false)
        #expect(inspector.document.rootNode == nil)

        _ = inspector.makeInspectorWebView()
        inspector.testHandleReadyMessage(contextID: contextID)
        await inspector.testWaitForBootstrap()

        #expect(inspector.document.rootNode != nil)
        #expect(inspector.testCurrentContextID == contextID)
        #expect(inspector.testCurrentDocumentURL == "https://example.com/a")
    }

    @Test
    func beginSelectionModeEnablesInspectModeOnCurrentTarget() async throws {
        var inspectModePayload: [String: Any]?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    inspectModePayload = payload["params"] as? [String: Any]
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()

        #expect(inspector.isSelectingElement)
        #expect((inspectModePayload?["enabled"] as? Bool) == true)
        #expect(inspectModePayload?["highlightConfig"] != nil)
    }

    @Test
    func cancelSelectionModeDisablesInspectModeOnCurrentTarget() async throws {
        var disableCount = 0
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = payload["params"] as? [String: Any]
                    if (params?["enabled"] as? Bool) == false {
                        disableCount += 1
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        await inspector.cancelSelectionMode()

        #expect(inspector.isSelectingElement == false)
        #expect(disableCount == 1)
    }

    @Test
    func selectionModeDoesNotDisablePageInteractionOnUIKit() async throws {
#if canImport(UIKit)
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()
        let initialScrollEnabled = webView.scrollView.isScrollEnabled
        let initialPanEnabled = webView.scrollView.panGestureRecognizer.isEnabled

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(webView.scrollView.isScrollEnabled == initialScrollEnabled)
        #expect(webView.scrollView.panGestureRecognizer.isEnabled == initialPanEnabled)

        await inspector.cancelSelectionMode()
        #expect(webView.scrollView.isScrollEnabled == initialScrollEnabled)
        #expect(webView.scrollView.panGestureRecognizer.isEnabled == initialPanEnabled)
#endif
    }

    @Test
    func pointerInspectSelectionUsesRuntimeHitTestAndRequestNode() async throws {
        var didEvaluateHitTest = false
        var requestedObjectID: String?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.Runtime.evaluate:
                    didEvaluateHitTest = true
                    return ["result": ["objectId": "node-object-6"]]
                case WITransportMethod.DOM.requestNode:
                    let params = payload["params"] as? [String: Any]
                    requestedObjectID = params?["objectId"] as? String
                    return ["nodeId": 6]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        await inspector.handlePointerInspectSelection(at: CGPoint(x: 40, y: 20))

        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6 && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(didEvaluateHitTest)
        #expect(requestedObjectID == "node-object-6")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func domInspectSelectsRealTransportNode() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6 && inspector.isSelectingElement == false
        }
        #expect(selected)
    }

    @Test
    func domInspectMaterializesSelectedNodeFromRequestedChildNodes() async throws {
        var requestedNodeIDs: [Int] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, _ in
            switch method {
            case WITransportMethod.DOM.getDocument:
                return makeDocumentResult(
                    url: "https://example.com/a",
                    bodyChildren: [[
                        "nodeId": 10,
                        "backendNodeId": 10,
                        "nodeType": 1,
                        "nodeName": "SECTION",
                        "localName": "section",
                        "nodeValue": "",
                        "attributes": ["id", "branch"],
                        "childNodeCount": 1,
                        "children": [],
                    ]]
                )
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestChildNodes:
                if let params = payload["params"] as? [String: Any],
                   let nodeID = params["nodeId"] as? Int {
                    requestedNodeIDs.append(nodeID)
                    if nodeID == 1 {
                        backend.emitPageEvent(
                            method: "DOM.setChildNodes",
                            params: [
                                "parentId": 10,
                                "nodes": [[
                                    "nodeId": 6,
                                    "backendNodeId": 6,
                                    "nodeType": 1,
                                    "nodeName": "A",
                                    "localName": "a",
                                    "nodeValue": "",
                                    "attributes": ["href", "/target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ]
                        )
                    }
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.nodeName == "A"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestedNodeIDs.contains(1))
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func inspectorInspectSelectsRealTransportNode() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    return ["nodeId": 6]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-6",
                ],
                "hints": [:],
            ]
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6 && inspector.isSelectingElement == false
        }
        #expect(selected)
    }

    @Test
    func inspectorInspectMaterializesSelectedNodeFromRequestedNode() async throws {
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, _, _ in
            switch method {
            case WITransportMethod.DOM.getDocument:
                return makeDocumentResult(
                    url: "https://example.com/a",
                    bodyChildren: []
                )
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                backend.emitPageEvent(
                    method: "DOM.setChildNodes",
                    params: [
                        "parentId": 3,
                        "nodes": [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]],
                    ]
                )
                return ["nodeId": 6]
            default:
                return [:]
            }
        }

        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-6",
                ],
                "hints": [:],
            ]
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.nodeName == "A"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func unresolvedInspectLeavesSelectionEmptyWithoutUserFacingError() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 999])

        let cleared = await waitForCondition {
            inspector.document.selectedNode == nil
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(cleared)
    }

    @Test
    func unresolvedInspectPreservesExistingSelection() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.isSelectingElement == false
        }
        #expect(selected)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 999])
        let preserved = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(preserved)
    }

    @Test
    func selectNodeForTestingResolvesSelectorAndAppliesSelection() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "H1",
                            "localName": "h1",
                            "nodeValue": "",
                            "attributes": ["id", "title"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.querySelector:
                    return ["nodeId": 6]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(cssSelector: "#title")

        #expect(inspector.document.selectedNode?.localID == 6)
        #expect(inspector.document.selectedNode?.selectorPath == "#title")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func selectNodeForTestingFallsBackToCurrentDocumentForSimpleSelector() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "H1",
                            "localName": "h1",
                            "nodeValue": "",
                            "attributes": ["id", "title"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.querySelector:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(cssSelector: "h1")

        #expect(inspector.document.selectedNode?.localID == 6)
        #expect(inspector.document.selectedNode?.selectorPath == "h1")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func selectNodeForTestingPreviewSelectsVisibleNode() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(
            preview: "<main>",
            selectorPath: "main"
        )

        #expect(inspector.document.selectedNode?.localID == 4)
        #expect(inspector.document.selectedNode?.selectorPath == "main")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func selectNodeForTestingClearsSelectionWhenSelectorDoesNotResolve() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.querySelector:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.applySelectionSnapshot(
            .init(
                localID: 4,
                preview: "<main>",
                attributes: [],
                path: ["html", "body", "main"],
                selectorPath: "#root",
                styleRevision: 0
            )
        )

        await #expect(throws: DOMOperationError.invalidSelection) {
            try await inspector.selectNodeForTesting(cssSelector: "#missing")
        }

        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func staleSelectionFailureDoesNotClearNewerSelection() async throws {
        var requestedObjectIDs: [String] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    let params = payload["params"] as? [String: Any]
                    let objectID = params?["objectId"] as? String
                    if let objectID {
                        requestedObjectIDs.append(objectID)
                    }
                    if objectID == "node-object-pending" {
                        return ["nodeId": 999]
                    }
                    return ["nodeId": 6]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-pending",
                ],
                "hints": [:],
            ]
        )

        try? await Task.sleep(nanoseconds: 80_000_000)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestedObjectIDs.contains("node-object-pending"))
    }

    @Test
    func selectedNodeSendsPersistentHighlightAndHidesItOnDocumentReload() async throws {
        var pageMethods: [String] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                pageMethods.append(method)
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled,
                     WITransportMethod.DOM.highlightNode,
                     WITransportMethod.DOM.hideHighlight:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.isSelectingElement == false
                && pageMethods.contains(WITransportMethod.DOM.highlightNode)
        }
        #expect(selected)

        try await inspector.reloadDocument()

        let reloaded = await waitForCondition {
            inspector.document.selectedNode == nil
        }
        #expect(reloaded)
        let highlightIndex = pageMethods.lastIndex(of: WITransportMethod.DOM.highlightNode)
        let hideHighlightIndex = pageMethods.lastIndex(of: WITransportMethod.DOM.hideHighlight)
        #expect(highlightIndex != nil)
        #expect(hideHighlightIndex != nil)
        if let highlightIndex, let hideHighlightIndex {
            #expect(hideHighlightIndex > highlightIndex)
        }
    }

    @Test
    func successfulInspectReappliesPersistentHighlightAfterInspectModeTeardown() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled,
                   let params = payload["params"] as? [String: Any] {
                    inspectModeEnabled = params["enabled"] as? Bool
                } else {
                    inspectModeEnabled = nil
                }
                pageCalls.append((method: method, inspectModeEnabled: inspectModeEnabled))

                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled,
                     WITransportMethod.DOM.highlightNode,
                     WITransportMethod.DOM.hideHighlight:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            guard let highlightIndex = pageCalls.lastIndex(where: {
                $0.method == WITransportMethod.DOM.highlightNode
            }) else {
                return false
            }
            let disableIndices = pageCalls.indices.filter {
                pageCalls[$0].method == WITransportMethod.DOM.setInspectModeEnabled
                    && pageCalls[$0].inspectModeEnabled == false
            }
            return inspector.document.selectedNode?.localID == 6
                && inspector.isSelectingElement == false
                && disableIndices.isEmpty
                && highlightIndex >= 0
        }
        #expect(selected)
    }

    @Test
    func unresolvedInspectRestoresExistingPersistentHighlight() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled,
                   let params = payload["params"] as? [String: Any] {
                    inspectModeEnabled = params["enabled"] as? Bool
                } else {
                    inspectModeEnabled = nil
                }
                pageCalls.append((method: method, inspectModeEnabled: inspectModeEnabled))

                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled,
                     WITransportMethod.DOM.highlightNode,
                     WITransportMethod.DOM.hideHighlight:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let initialSelection = await waitForCondition {
            inspector.document.selectedNode?.localID == 6 && inspector.isSelectingElement == false
        }
        #expect(initialSelection)

        let initialCallCount = pageCalls.count

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 999])

        let preserved = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            let delta = Array(pageCalls.dropFirst(initialCallCount))
            guard let highlightIndex = delta.lastIndex(where: {
                $0.method == WITransportMethod.DOM.highlightNode
            }) else {
                return false
            }
            let disableIndices = delta.indices.filter {
                delta[$0].method == WITransportMethod.DOM.setInspectModeEnabled
                    && delta[$0].inspectModeEnabled == false
            }
            return inspector.document.selectedNode?.localID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
                && disableIndices.isEmpty
                && highlightIndex >= 0
        }
        #expect(preserved)
    }

    @Test
    func overlayMarkedNodesAreFilteredOutOfTransportDocument() async {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(
                    url: "https://example.com/a",
                    bodyChildren: [
                        [
                            "nodeId": 90,
                            "backendNodeId": 90,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": ["data-web-inspector-overlay", "true"],
                            "childNodeCount": 0,
                            "children": [],
                        ],
                        [
                            "nodeId": 4,
                            "backendNodeId": 4,
                            "nodeType": 1,
                            "nodeName": "MAIN",
                            "localName": "main",
                            "nodeValue": "",
                            "attributes": ["id", "root"],
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 5,
                                "backendNodeId": 5,
                                "nodeType": 1,
                                "nodeName": "DIV",
                                "localName": "div",
                                "nodeValue": "",
                                "attributes": ["id", "target"],
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                        ],
                    ]
                )
            }
        )
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        #expect(inspector.document.node(localID: 90) == nil)
        let bodyNode = inspector.document.node(localID: 3)
        #expect(bodyNode?.childCount == 1)
        #expect(bodyNode?.children.count == 1)
    }
}

@MainActor
private func makeInspector(using backend: FakeDOMTransportBackend) -> WIDOMInspector {
    let sharedTransport = WISharedInspectorTransport(sessionFactory: {
        WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
    })
    return WIDOMInspector(sharedTransport: sharedTransport)
}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

@MainActor
private func waitForCondition(
    maxAttempts: Int = 200,
    intervalNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxAttempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return condition()
}

private func makeDocumentResult(
    url: String,
    bodyChildren: [[String: Any]]? = nil,
    mainChildren: [[String: Any]]? = nil
) -> [String: Any] {
    let resolvedMainChildren = mainChildren ?? [[
        "nodeId": 5,
        "backendNodeId": 5,
        "nodeType": 1,
        "nodeName": "DIV",
        "localName": "div",
        "nodeValue": "",
        "attributes": ["id", "target"],
        "childNodeCount": 0,
        "children": [],
    ]]
    let resolvedBodyChildren = bodyChildren ?? [[
        "nodeId": 4,
        "backendNodeId": 4,
        "nodeType": 1,
        "nodeName": "MAIN",
        "localName": "main",
        "nodeValue": "",
        "attributes": ["id", "root"],
        "childNodeCount": resolvedMainChildren.count,
        "children": resolvedMainChildren,
    ]]

    return [
        "root": [
            "nodeId": 1,
            "backendNodeId": 1,
            "nodeType": 9,
            "nodeName": "#document",
            "localName": "",
            "nodeValue": "",
            "documentURL": url,
            "childNodeCount": 1,
            "children": [
                [
                    "nodeId": 2,
                    "backendNodeId": 2,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [
                        [
                            "nodeId": 3,
                            "backendNodeId": 3,
                            "nodeType": 1,
                            "nodeName": "BODY",
                            "localName": "body",
                            "nodeValue": "",
                            "childNodeCount": resolvedBodyChildren.count,
                            "children": resolvedBodyChildren,
                        ],
                    ],
                ],
            ],
        ],
    ]
}

@MainActor
private final class FakeDOMTransportBackend: WITransportPlatformBackend {
    var supportSnapshot: WITransportSupportSnapshot
    var pageResultProvider: ((String, [String: Any], String) throws -> [String: Any])?

    private var messageSink: (any WITransportBackendMessageSink)?
    private var currentTargetIdentifier = "page-A"

    init(
        capabilities: Set<WITransportCapability> = [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain],
        pageResultProvider: ((String, [String: Any], String) throws -> [String: Any])? = nil
    ) {
        self.supportSnapshot = .supported(
            backendKind: .macOSNativeInspector,
            capabilities: capabilities
        )
        self.pageResultProvider = pageResultProvider
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        _ = webView
        self.messageSink = messageSink
        messageSink.didReceiveRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
        )
        await messageSink.waitForPendingMessages()
    }

    func detach() {
        messageSink = nil
    }

    func sendRootMessage(_ message: String) throws {
        _ = message
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        currentTargetIdentifier = targetIdentifier
        let payload = try decodeMessagePayload(message)
        guard let method = payload["method"] as? String else {
            return
        }
        let result = try pageResultProvider?(method, payload, targetIdentifier) ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let resultString = String(data: data, encoding: .utf8) else {
            messageSink?.didReceivePageMessage(#"{"id":\#(outerIdentifier),"result":{}}"#, targetIdentifier: targetIdentifier)
            return
        }
        messageSink?.didReceivePageMessage(
            #"{"id":\#(outerIdentifier),"result":\#(resultString)}"#,
            targetIdentifier: targetIdentifier
        )
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        _ = scope
        if method == WITransportMethod.DOM.enable {
            return Data("{}".utf8)
        }
        return nil
    }

    func emitPageEvent(method: String, params: [String: Any], targetIdentifier: String? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            return
        }
        messageSink?.didReceivePageMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#,
            targetIdentifier: targetIdentifier ?? currentTargetIdentifier
        )
    }

    func emitRootEvent(method: String, params: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            return
        }
        messageSink?.didReceiveRootMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#
        )
    }

    private func decodeMessagePayload(_ message: String) throws -> [String: Any] {
        let data = Data(message.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}

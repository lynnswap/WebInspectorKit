import Foundation
import OSLog
import Testing
import WebKit
#if canImport(UIKit)
import UIKit
#endif
@testable import WebInspectorEngine
@_spi(Monocly) @testable import WebInspectorRuntime
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized)
struct WIDOMInspectorTests {
#if canImport(UIKit)
    final class FakeSceneActivationTarget: NSObject, WIDOMUIKitSceneActivationTarget {
        var activationState: UIScene.ActivationState
        var sceneSession: UISceneSession?

        init(
            activationState: UIScene.ActivationState,
            sceneSession: UISceneSession? = nil
        ) {
            self.activationState = activationState
            self.sceneSession = sceneSession
        }
    }

    final class FakeSceneActivationRequester: WIDOMUIKitSceneActivationRequesting {
        var requestCount = 0
        var requestError: Error?
        var onRequest: (@MainActor (any WIDOMUIKitSceneActivationTarget) async -> Void)?

        func requestActivation(
            of target: any WIDOMUIKitSceneActivationTarget,
            requestingScene _: UIScene?,
            errorHandler: ((any Error) -> Void)?
        ) {
            requestCount += 1
            if let requestError {
                errorHandler?(requestError)
                return
            }

            if let onRequest {
                Task { @MainActor in
                    await onRequest(target)
                }
            }
        }
    }
#endif

    @Test
    func selectionDiagnosticMilestonesStillEmitWithoutVerboseConsoleLogs() {
        #expect(
            WIDOMInspector.shouldEmitSelectionDiagnosticToConsoleForTesting(
                "applySelection updated document",
                level: .default,
                verboseConsoleDiagnostics: false
            )
        )
        #expect(
            WIDOMInspector.shouldEmitSelectionDiagnosticToConsoleForTesting(
                "beginFreshContext requested",
                level: .default,
                verboseConsoleDiagnostics: false
            )
        )
    }

    @Test
    func selectionDiagnosticNoiseIsSuppressedWithoutVerboseConsoleLogs() {
        #expect(
            WIDOMInspector.shouldEmitSelectionDiagnosticToConsoleForTesting(
                "attach requested",
                level: .default,
                verboseConsoleDiagnostics: false
            ) == false
        )
        #expect(
            WIDOMInspector.shouldEmitSelectionDiagnosticToConsoleForTesting(
                "pending inspect progress observed",
                level: .debug,
                verboseConsoleDiagnostics: false
            ) == false
        )
    }

    @Test
    func selectionDiagnosticVerboseModeRestoresConsoleTrace() {
        #expect(
            WIDOMInspector.shouldEmitSelectionDiagnosticToConsoleForTesting(
                "attach requested",
                level: .default,
                verboseConsoleDiagnostics: true
            )
        )
        #expect(
            WIDOMInspector.shouldEmitSelectionDiagnosticToConsoleForTesting(
                "pending inspect progress observed",
                level: .debug,
                verboseConsoleDiagnostics: true
            )
        )
    }

    @Test
    func sameWebViewReattachKeepsContextID() async {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
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
        let firstWebView = makeTestWebView()
        let secondWebView = makeTestWebView()

        await inspector.attach(to: firstWebView)
        let firstContextID = try #require(inspector.testCurrentContextID)

        await inspector.attach(to: secondWebView)
        let secondContextID = try #require(inspector.testCurrentContextID)

        #expect(secondContextID > firstContextID)
    }

    @Test
    func payloadNormalizerEmbedsContentDocumentAsCanonicalChild() async throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData(makeIFrameDocumentResult(url: "https://example.com/a")),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }
        let htmlNode = try #require(snapshot.root.children.first)
        let bodyNode = try #require(htmlNode.children.first(where: { $0.localName == "body" }))
        let mainNode = try #require(bodyNode.children.first(where: { $0.localName == "main" }))
        let iframeNode = try #require(mainNode.children.first(where: { $0.localName == "iframe" }))
        let nestedDocument = try #require(iframeNode.contentDocument)

        #expect(iframeNode.frameID == "frame-child")
        #expect(iframeNode.childCount == 1)
        #expect(iframeNode.regularChildCount == 0)
        #expect(iframeNode.regularChildren.isEmpty)
        #expect(iframeNode.effectiveChildren.map(\.nodeID) == [nestedDocument.nodeID])
        #expect(nestedDocument.nodeType == .document)
        #expect(nestedDocument.frameID == "frame-child")
        #expect(nestedDocument.children.first?.children.first?.localName == "button")
    }

    @Test
    func payloadNormalizerKeepsWebKitSpecialChildrenSeparate() async throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData([
                    "root": [
                        "nodeId": 1,
                        "nodeType": 9,
                        "nodeName": "#document",
                        "localName": "",
                        "nodeValue": "",
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "SECTION",
                            "localName": "section",
                            "nodeValue": "",
                            "attributes": [],
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 14,
                                "nodeType": 1,
                                "nodeName": "P",
                                "localName": "p",
                                "nodeValue": "",
                                "attributes": [],
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                            "shadowRoots": [[
                                "nodeId": 13,
                                "nodeType": 11,
                                "nodeName": "#shadow-root",
                                "localName": "",
                                "nodeValue": "",
                                "shadowRootType": "open",
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                            "templateContent": [
                                "nodeId": 11,
                                "nodeType": 11,
                                "nodeName": "#document-fragment",
                                "localName": "",
                                "nodeValue": "",
                                "childNodeCount": 0,
                                "children": [],
                            ],
                            "pseudoElements": [[
                                "nodeId": 15,
                                "nodeType": 1,
                                "nodeName": "::after",
                                "localName": "",
                                "nodeValue": "",
                                "pseudoType": "after",
                                "childNodeCount": 0,
                                "children": [],
                            ], [
                                "nodeId": 12,
                                "nodeType": 1,
                                "nodeName": "::before",
                                "localName": "",
                                "nodeValue": "",
                                "pseudoType": "before",
                                "childNodeCount": 0,
                                "children": [],
                            ], [
                                "nodeId": 16,
                                "nodeType": 1,
                                "nodeName": "::marker",
                                "localName": "",
                                "nodeValue": "",
                                "pseudoType": "marker",
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                        ]],
                    ],
                ]),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }

        let host = try #require(snapshot.root.children.first)

        #expect(host.regularChildren.map(\.nodeID) == [14])
        #expect(host.contentDocument == nil)
        #expect(host.shadowRoots.map(\.nodeID) == [13])
        #expect(host.shadowRoots.first?.shadowRootType == "open")
        #expect(host.templateContent?.nodeID == 11)
        #expect(host.beforePseudoElement?.nodeID == 12)
        #expect(host.beforePseudoElement?.pseudoType == "before")
        #expect(host.otherPseudoElements.map(\.nodeID) == [16])
        #expect(host.otherPseudoElements.first?.pseudoType == "marker")
        #expect(host.afterPseudoElement?.nodeID == 15)
        #expect(host.afterPseudoElement?.pseudoType == "after")
        #expect(host.effectiveChildren.map(\.nodeID) == [13, 14])
        #expect(host.visibleDOMTreeChildren.map(\.nodeID) == [11, 12, 16, 13, 14, 15])
    }

    @Test
    func payloadNormalizerTreatsPresentEmptyChildrenAsLoadedEmpty() async throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData([
                    "root": [
                        "nodeId": 1,
                        "nodeType": 9,
                        "nodeName": "#document",
                        "localName": "",
                        "nodeValue": "",
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                            "childNodeCount": 1,
                            "children": [],
                        ]],
                    ],
                ]),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }

        let div = try #require(snapshot.root.regularChildren.first)
        #expect(div.childCount == 0)
        #expect(div.regularChildCount == 0)
        #expect(div.regularChildrenAreLoaded)
        #expect(div.regularChildren.isEmpty)
        #expect(div.visibleDOMTreeChildren.isEmpty)
    }

    @Test
    func payloadNormalizerKeepsOmittedChildrenUnrequested() async throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData([
                    "root": [
                        "nodeId": 1,
                        "nodeType": 9,
                        "nodeName": "#document",
                        "localName": "",
                        "nodeValue": "",
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                            "childNodeCount": 2,
                        ]],
                    ],
                ]),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }

        let div = try #require(snapshot.root.regularChildren.first)
        #expect(div.regularChildCount == 2)
        #expect(!div.regularChildrenAreLoaded)
        #expect(div.regularChildren.isEmpty)
    }

    @Test
    func payloadNormalizerTreatsUnknownElementChildCountAsUnrequested() async throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData([
                    "root": [
                        "nodeId": 1,
                        "nodeType": 9,
                        "nodeName": "#document",
                        "localName": "",
                        "nodeValue": "",
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                        ], [
                            "nodeId": 11,
                            "nodeType": 3,
                            "nodeName": "#text",
                            "localName": "",
                            "nodeValue": "text",
                        ]],
                    ],
                ]),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }

        let div = try #require(snapshot.root.regularChildren.first)
        let text = try #require(snapshot.root.regularChildren.dropFirst().first)
        #expect(div.regularChildCount == 1)
        #expect(!div.regularChildrenAreLoaded)
        #expect(text.regularChildCount == 0)
        #expect(!text.regularChildrenAreLoaded)
    }

    @Test
    func payloadNormalizerPreservesProtocolNodeIDsForDetachedRoots() async throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.setChildNodes",
                paramsData: jsonData([
                    "nodes": [[
                        "nodeId": 900,
                        "nodeType": 9,
                        "nodeName": "#document",
                        "localName": "",
                        "nodeValue": "",
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 1093,
                            "nodeType": 1,
                            "nodeName": "IMG",
                            "localName": "img",
                            "nodeValue": "",
                            "attributes": ["id", "detached-target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]],
                    ]]
                ])
            )
        )

        guard case let .mutations(bundle) = delta else {
            Issue.record("Expected mutation bundle")
            return
        }
        guard case let .setDetachedRoots(nodes) = try #require(bundle.events.first) else {
            Issue.record("Expected detached roots mutation")
            return
        }

        #expect(nodes.count == 1)
        #expect(nodes.first?.nodeID == 900)
        #expect(nodes.first?.children.first?.nodeID == 1093)
    }

    @Test
    func payloadNormalizerNormalizesLiveSpecialChildEvents() async throws {
        let normalizer = DOMPayloadNormalizer()

        let shadowPushDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.shadowRootPushed",
                paramsData: jsonData([
                    "hostId": 10,
                    "root": [
                        "nodeId": 13,
                        "nodeType": 11,
                        "nodeName": "#shadow-root",
                        "localName": "",
                        "nodeValue": "",
                        "shadowRootType": "open",
                        "childNodeCount": 0,
                        "children": [],
                    ],
                ])
            )
        )
        guard case let .mutations(shadowPushBundle) = shadowPushDelta,
              case let .shadowRootPushed(hostNodeID, root) = try #require(shadowPushBundle.events.first)
        else {
            Issue.record("Expected shadowRootPushed mutation")
            return
        }
        #expect(hostNodeID == 10)
        #expect(root.nodeID == 13)
        #expect(root.shadowRootType == "open")

        let shadowPopDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.shadowRootPopped",
                paramsData: jsonData([
                    "hostId": 10,
                    "rootId": 13,
                ])
            )
        )
        guard case let .mutations(shadowPopBundle) = shadowPopDelta,
              case let .shadowRootPopped(poppedHostNodeID, rootNodeID) = try #require(shadowPopBundle.events.first)
        else {
            Issue.record("Expected shadowRootPopped mutation")
            return
        }
        #expect(poppedHostNodeID == 10)
        #expect(rootNodeID == 13)

        let pseudoAddedDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.pseudoElementAdded",
                paramsData: jsonData([
                    "parentId": 10,
                    "pseudoElement": [
                        "nodeId": 12,
                        "nodeType": 1,
                        "nodeName": "::before",
                        "localName": "",
                        "nodeValue": "",
                        "pseudoType": "before",
                        "childNodeCount": 0,
                        "children": [],
                    ],
                ])
            )
        )
        guard case let .mutations(pseudoAddedBundle) = pseudoAddedDelta,
              case let .pseudoElementAdded(parentNodeID, pseudoElement) = try #require(pseudoAddedBundle.events.first)
        else {
            Issue.record("Expected pseudoElementAdded mutation")
            return
        }
        #expect(parentNodeID == 10)
        #expect(pseudoElement.nodeID == 12)
        #expect(pseudoElement.pseudoType == "before")

        let markerPseudoAddedDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.pseudoElementAdded",
                paramsData: jsonData([
                    "parentId": 10,
                    "pseudoElement": [
                        "nodeId": 16,
                        "nodeType": 1,
                        "nodeName": "::marker",
                        "localName": "",
                        "nodeValue": "",
                        "pseudoType": "marker",
                        "childNodeCount": 0,
                        "children": [],
                    ],
                ])
            )
        )
        guard case let .mutations(markerPseudoAddedBundle) = markerPseudoAddedDelta,
              case let .pseudoElementAdded(markerParentNodeID, markerPseudoElement) = try #require(markerPseudoAddedBundle.events.first)
        else {
            Issue.record("Expected marker pseudoElementAdded mutation")
            return
        }
        #expect(markerParentNodeID == 10)
        #expect(markerPseudoElement.nodeID == 16)
        #expect(markerPseudoElement.pseudoType == "marker")

        let pseudoRemovedDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.pseudoElementRemoved",
                paramsData: jsonData([
                    "parentId": 10,
                    "pseudoElementId": 12,
                ])
            )
        )
        guard case let .mutations(pseudoRemovedBundle) = pseudoRemovedDelta,
              case let .pseudoElementRemoved(removedParentNodeID, pseudoElementNodeID) = try #require(pseudoRemovedBundle.events.first)
        else {
            Issue.record("Expected pseudoElementRemoved mutation")
            return
        }
        #expect(removedParentNodeID == 10)
        #expect(pseudoElementNodeID == 12)
    }

    @Test
    func payloadNormalizerPreservesChildInsertionPreviousSiblingState() async throws {
        let normalizer = DOMPayloadNormalizer()
        let nodePayload: [String: Any] = [
            "nodeId": 12,
            "nodeType": 1,
            "nodeName": "SPAN",
            "localName": "span",
            "nodeValue": "",
            "attributes": [],
            "childNodeCount": 0,
            "children": [],
        ]

        let missingPreviousDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.childNodeInserted",
                paramsData: jsonData([
                    "parentNodeId": 10,
                    "node": nodePayload,
                ])
            )
        )
        guard case let .mutations(missingBundle) = missingPreviousDelta,
              case let .childNodeInserted(_, missingPreviousSibling, _) = try #require(missingBundle.events.first)
        else {
            Issue.record("Expected childNodeInserted mutation")
            return
        }
        #expect(missingPreviousSibling == .missing)

        let firstChildDelta = try #require(
            await normalizer.normalizeDOMEvent(
                method: "DOM.childNodeInserted",
                paramsData: jsonData([
                    "parentNodeId": 10,
                    "previousNodeId": 0,
                    "node": nodePayload,
                ])
            )
        )
        guard case let .mutations(firstChildBundle) = firstChildDelta,
              case let .childNodeInserted(_, firstChildPreviousSibling, _) = try #require(firstChildBundle.events.first)
        else {
            Issue.record("Expected childNodeInserted mutation")
            return
        }
        #expect(firstChildPreviousSibling == .firstChild)
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        #expect(inspector.hasPageWebView)

        await inspector.suspend()

        #expect(!inspector.hasPageWebView)
        #expect(inspector.testCurrentContextID == nil)
    }

    @Test
    func attachedPageWebViewDeallocationClearsAttachmentState() async {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        weak var releasedWebView: WKWebView?

        do {
            let webView = makeTestWebView()
            releasedWebView = webView
            await inspector.attach(to: webView)
            #expect(inspector.hasPageWebView)
        }

        let released = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            releasedWebView == nil && inspector.hasPageWebView == false
        }
        #expect(released)
    }

    @Test
    func attachFailureKeepsPageAttachmentButLeavesSelectionUnavailable() async {
        let backend = FakeDOMTransportBackend()
        backend.attachError = WITransportError.attachFailed("simulated attach failure")
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)

        #expect(inspector.hasPageWebView)
        #expect(inspector.testIsPageReadyForSelection == false)
        #expect(inspector.testCurrentContextID == nil)
    }

    @Test
    func sameWebViewAttachFailureClearsStaleDOMState() async {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        await inspector.testDetachSharedTransportOnly()
        backend.attachError = WITransportError.attachFailed("simulated attach failure")
        await inspector.attach(to: webView)

        #expect(inspector.hasPageWebView)
        #expect(inspector.testIsPageReadyForSelection == false)
        #expect(inspector.testCurrentContextID == nil)
        #expect(inspector.document.rootNode == nil)
    }

    @Test
    func attachUsesDerivedCommittedPageTargetWhenObservedTargetIsMissing() async {
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(
                    url: targetIdentifier == "page-A"
                        ? "https://example.com/a"
                        : "https://example.com/other"
                )
            }
        )
        let inspector = makeInspector(
            using: backend,
            derivedPageTargetIdentifier: "page-A"
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)

        let loadedDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(loadedDocument)
    }

#if canImport(UIKit)
    @Test
    func attachReinstallsPointerDisconnectObserverAfterSuspend() async {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        #expect(inspector.pointerDisconnectObserver != nil)

        await inspector.suspend()
        #expect(inspector.pointerDisconnectObserver == nil)

        let reattachedWebView = makeTestWebView()
        await inspector.attach(to: reattachedWebView)
        #expect(inspector.pointerDisconnectObserver != nil)
    }
#endif

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
    func targetCreatedPrefersCommittedTargetOverProvisionalEnvelopeWhenObservedTargetIsNil() async {
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: targetIdentifier == "page-B" ? "https://example.com/b" : "https://example.com/a")
            }
        )
        let inspector = makeInspector(
            using: backend,
            derivedPageTargetIdentifier: "page-A"
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        let loadedCommittedDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(loadedCommittedDocument)
    }

    @Test
    func targetDestroyedFallsBackToCommittedTargetWhenObservedTargetIsNil() async throws {
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: targetIdentifier == "page-B" ? "https://example.com/b" : "https://example.com/a")
            }
        )
        let inspector = makeInspector(
            using: backend,
            derivedPageTargetIdentifier: "page-A"
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        let loadedCommittedDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(loadedCommittedDocument)

        await inspector.testBeginFreshContext(
            documentURL: "https://example.com/b",
            targetIdentifier: "page-B",
            loadImmediately: true,
            isFreshDocument: true
        )

        let provisionalContextID = try #require(inspector.testCurrentContextID)
        let loadedProvisionalDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID == provisionalContextID
                && inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(loadedProvisionalDocument)

        backend.emitRootEvent(
            method: "Target.targetDestroyed",
            params: ["targetId": "page-B"]
        )

        let reloadedCommittedDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID != provisionalContextID
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(reloadedCommittedDocument)
    }

    @Test
    func targetCreatedDoesNotReplaceAlreadyLoadedDerivedDocumentWithoutLifecycleTransition() async throws {
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: targetIdentifier == "page-B" ? "https://example.com/b" : "https://example.com/a")
            }
        )
        let inspector = makeInspector(
            using: backend,
            derivedPageTargetIdentifier: "page-A"
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let loadedDerivedDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(loadedDerivedDocument)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": false,
                ],
            ]
        )

        let stayedOnDerivedDocument = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(stayedOnDerivedDocument)
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
    func reloadPageReloadsWhenOnlyDocumentUpdatedArrives() async throws {
        var currentURL = "https://example.com/a"
        var getDocumentCallCount = 0
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                getDocumentCallCount += 1
                return makeDocumentResult(url: currentURL)
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(initiallyReady)

        inspector.document.applySelectionSnapshot(
            .init(
                nodeID: 5,
                attributes: [],
                path: ["html", "body", "main", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )
        #expect(inspector.document.selectedNode?.nodeID == 5)

        currentURL = "https://example.com/b"
        try await inspector.reloadPage()

        #expect(inspector.document.documentState == .loading)
        #expect(inspector.document.rootNode == nil)
        #expect(inspector.document.selectedNode == nil)

        backend.emitPageEvent(
            method: "DOM.attributeModified",
            params: ["nodeId": 5, "name": "class", "value": "stale"],
            targetIdentifier: "page-A"
        )
        let staleMutationStartedLoad = await waitForCondition(maxAttempts: 10) {
            getDocumentCallCount > 1 || inspector.testIsReady
        }
        #expect(staleMutationStartedLoad == false)
        #expect(inspector.document.documentState == .loading)

        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:], targetIdentifier: "page-A")

        let reloaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(reloaded)
    }

    @Test
    func documentUpdatedDuringActiveBootstrapDoesNotRestartBootstrap() async {
        var getDocumentCallCount = 0
        var backend: FakeDOMTransportBackend!
        backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, _, _ in
            if method == WITransportMethod.DOM.enable {
                backend.emitPageEvent(method: "DOM.documentUpdated", params: [:], targetIdentifier: "page-A")
            }
            guard method == WITransportMethod.DOM.getDocument else {
                return [:]
            }
            getDocumentCallCount += 1
            return makeDocumentResult(url: "https://example.com/a")
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)

        let loaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(loaded)
        #expect(getDocumentCallCount <= 2)
    }

    @Test
    func documentUpdatedAfterFailedBootstrapResetsDocumentStateBeforeRetry() async {
        var getDocumentCallCount = 0
        var retryDocumentState: DOMDocumentState?
        var inspector: WIDOMInspector!
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                getDocumentCallCount += 1
                if getDocumentCallCount == 1 {
                    throw DOMOperationError.scriptFailure("initial load failed")
                }
                retryDocumentState = inspector.document.documentState
                return makeDocumentResult(url: "https://example.com/a")
            }
        )
        inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)

        let failed = await waitForCondition {
            inspector.document.documentState == .failed
        }
        #expect(failed)

        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:], targetIdentifier: "page-A")

        let reloaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.document.rootNode != nil
        }
        #expect(reloaded)
        #expect(retryDocumentState == .loading)
    }

    @Test
    func sameWebViewReattachRestartsLoadingDocumentAfterReloadPage() async throws {
        var currentURL = "https://example.com/a"
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: currentURL)
            }
        )
        let inspector = makeInspector(
            using: backend,
            derivedPageTargetIdentifier: "page-A"
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(initiallyReady)

        currentURL = "https://example.com/b"
        try await inspector.reloadPage()

        #expect(inspector.document.documentState == .loading)
        #expect(inspector.document.rootNode == nil)

        await inspector.attach(to: webView)

        let reloaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(reloaded)
    }

    @Test
    func targetCreatedDuringUnknownTargetLoadingStartsDocumentLoad() async {
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)

        #expect(inspector.document.documentState == .loading)
        #expect(inspector.testIsReady == false)
        #expect(inspector.document.rootNode == nil)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-A",
                    "type": "page",
                    "isProvisional": false,
                ],
            ]
        )

        let loaded = await waitForCondition {
            inspector.testIsReady
                && inspector.document.documentState == .ready
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(loaded)
    }

    @Test
    func unknownParentSetChildNodesDoesNotRefreshCurrentDocumentFromTransport() async throws {
        var getDocumentCallCount = 0
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                getDocumentCallCount += 1
                return makeDocumentResult(
                    url: "https://example.com/a",
                    mainChildren: [[
                        "nodeId": 6,
                        "nodeType": 1,
                        "nodeName": "A",
                        "localName": "a",
                        "nodeValue": "",
                        "attributes": ["id", "first"],
                        "childNodeCount": 0,
                        "children": [],
                    ]]
                )
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady
                && inspector.document.node(nodeID: 6) != nil
                && getDocumentCallCount == 1
        }
        #expect(ready)
        let firstContextID = try #require(inspector.testCurrentContextID)

        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 999,
                "nodes": [[
                    "nodeId": 18,
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "nodeValue": "",
                    "attributes": ["id", "orphan"],
                    "childNodeCount": 0,
                    "children": [],
                ]],
            ]
        )
        await backend.waitForPendingMessages()

        #expect(inspector.testIsReady)
        #expect(inspector.testCurrentContextID == firstContextID)
        #expect(inspector.testCurrentDocumentURL == "https://example.com/a")
        #expect(getDocumentCallCount == 1)
        #expect(inspector.document.node(nodeID: 6) != nil)
        #expect(inspector.document.node(nodeID: 16) == nil)
    }

    @Test
    func documentUpdatedFreshContextAllowsSelectionModeAgain() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var documentVersion = 0
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if documentVersion == 0 {
                        return makeDocumentResult(
                            url: "https://example.com/a",
                            mainChildren: [[
                                "nodeId": 6,
                                "nodeType": 1,
                                "nodeName": "A",
                                "localName": "a",
                                "nodeValue": "",
                                "attributes": ["id", "first"],
                                "childNodeCount": 0,
                                "children": [],
                            ]]
                        )
                    }
                    return makeDocumentResult(
                        url: "https://example.com/b",
                        mainChildren: [[
                            "nodeId": 16,
                            "nodeType": 1,
                            "nodeName": "SECTION",
                            "localName": "section",
                            "nodeValue": "",
                            "attributes": ["id", "second"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let initiallySelected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
        }
        #expect(initiallySelected)

        let firstContextID = try #require(inspector.testCurrentContextID)
        documentVersion = 1
        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])

        let freshContextReady = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID != firstContextID
                && inspector.testCurrentDocumentURL == "https://example.com/b"
                && inspector.document.selectedNode == nil
        }
        #expect(freshContextReady)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 16])

        let reselectionReady = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 16
                && inspector.document.selectedNode?.nodeName == "section"
                && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(inspector.document.selectedNode?.nodeID != 6)
        #expect(inspectModeEnabledValues == [true, false, true, false])
    }

    @Test
    func firstSelectionAfterFreshContextKeepsExistingTransportAttachment() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var documentVersion = 0
        let backend = FakeDOMTransportBackend(
            emitsInitialPageTargetCreatedOnAttach: false,
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if documentVersion == 0 {
                        return makeDocumentResult(url: "https://example.com/a")
                    }
                    return makeDocumentResult(url: "https://example.com/b")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            derivedPageTargetIdentifier: "page-A"
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)
        #expect(backend.attachCount == 1)

        documentVersion = 1
        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:], targetIdentifier: "page-A")

        let freshContextReady = await waitForCondition {
            inspector.testIsReady
                && inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(freshContextReady)
        #expect(backend.attachCount == 1)

        try await inspector.beginSelectionMode()
        #expect(backend.attachCount == 1)
        #expect(inspector.isSelectingElement)
        #expect(inspectModeEnabledValues == [true])
    }

    @Test
    func provisionalNavigationCommitAllowsSelectionModeAgain() async throws {
        var inspectModeEnabledValues: [Bool] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if targetIdentifier == "page-B" {
                        return makeDocumentResult(
                            url: "https://example.com/b",
                            mainChildren: [[
                                "nodeId": 16,
                                "nodeType": 1,
                                "nodeName": "SECTION",
                                "localName": "section",
                                "nodeValue": "",
                                "attributes": ["id", "second"],
                                "childNodeCount": 0,
                                "children": [],
                            ]]
                        )
                    }
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["id", "first"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let initiallySelected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
        }
        #expect(initiallySelected)

        let firstContextID = try #require(inspector.testCurrentContextID)
        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        let committedReady = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID != firstContextID
                && inspector.testCurrentDocumentURL == "https://example.com/b"
                && inspector.document.selectedNode == nil
        }
        #expect(committedReady)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "DOM.inspect",
            params: ["nodeId": 16],
            targetIdentifier: "page-B"
        )

        let reselectionReady = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 16
                && inspector.document.selectedNode?.nodeName == "section"
                && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(inspectModeEnabledValues == [true, false, true, false])
    }

    @Test
    func selectionModeRefreshesFreshContextWhenTransportTargetAdvancedBeforeLifecycleDelivery() async throws {
        var inspectModeEnabledValues: [Bool] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if targetIdentifier == "page-B" {
                        return makeDocumentResult(
                            url: "https://example.com/b",
                            mainChildren: [[
                                "nodeId": 16,
                                "nodeType": 1,
                                "nodeName": "SECTION",
                                "localName": "section",
                                "nodeValue": "",
                                "attributes": ["id", "second"],
                                "childNodeCount": 0,
                                "children": [],
                            ]]
                        )
                    }
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["id", "first"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let firstContextID = try #require(inspector.testCurrentContextID)
        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        do {
            try await inspector.beginSelectionMode()
            Issue.record("Expected stale target selection mode activation to refresh instead")
        } catch {}

        let committedReady = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentContextID != firstContextID
                && inspector.testCurrentDocumentURL == "https://example.com/b"
                && inspector.document.selectedNode == nil
        }
        #expect(committedReady)
        #expect(inspectModeEnabledValues.isEmpty)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "DOM.inspect",
            params: ["nodeId": 16],
            targetIdentifier: "page-B"
        )

        let reselectionReady = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 16
                && inspector.document.selectedNode?.nodeName == "section"
                && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func freshContextRefreshesNativeDocumentAfterDocumentUpdated() async throws {
        var documentVersion = 0
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                if documentVersion == 0 {
                    return makeDocumentResult(url: "https://example.com/a")
                }
                return makeDocumentResult(url: "https://example.com/b")
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(initiallyReady)

        let firstContextID = try #require(inspector.testCurrentContextID)
        documentVersion = 1
        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])

        let advancedToFreshContext = await waitForCondition {
            guard let currentContextID = inspector.testCurrentContextID,
                  currentContextID != firstContextID
            else {
                return false
            }
            return true
        }
        #expect(advancedToFreshContext)

        let currentContextID = try #require(inspector.testCurrentContextID)
        let refreshedDocumentReady = await waitForCondition {
            inspector.testCurrentContextID == currentContextID
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(refreshedDocumentReady)

        #expect(inspector.testCurrentContextID == currentContextID)
    }

    @Test
    func provisionalNavigationRefreshesNativeDocumentForNewContext() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: targetIdentifier == "page-B" ? "https://example.com/b" : "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
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

        let advancedToNewContext = await waitForCondition {
            guard let currentContextID = inspector.testCurrentContextID,
                  currentContextID != firstContextID,
                  inspector.testCurrentDocumentURL == "https://example.com/b"
            else {
                return false
            }
            return true
        }
        #expect(advancedToNewContext)

        let currentContextID = try #require(inspector.testCurrentContextID)

        #expect(inspector.testCurrentContextID == currentContextID)
        #expect(inspector.testCurrentDocumentURL == "https://example.com/b")
    }

    @Test
    func loadingFreshContextRefreshesAfterDeferredDOMMutations() async throws {
        let backend = FakeDOMTransportBackend()
        var pageBGetDocumentCallCount = 0
        var identityBeforeFollowUpReplacement: UUID?
        var inspector: WIDOMInspector!
        backend.pageResultProvider = { method, _, targetIdentifier in
            guard method == WITransportMethod.DOM.getDocument else {
                return [:]
            }
            if targetIdentifier == "page-B" {
                pageBGetDocumentCallCount += 1
                if pageBGetDocumentCallCount == 1 {
                    backend.emitPageEvent(
                        method: "DOM.childNodeCountUpdated",
                        params: [
                            "nodeId": 16,
                            "childNodeCount": 1,
                        ],
                        targetIdentifier: "page-B"
                    )
                    return makeDocumentResult(
                        url: "https://example.com/b",
                        mainChildren: [[
                            "nodeId": 16,
                            "nodeType": 1,
                            "nodeName": "SECTION",
                            "localName": "section",
                            "nodeValue": "",
                            "attributes": ["id", "stale-first-load"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                }
                identityBeforeFollowUpReplacement = inspector.document.rootNode?.id.documentIdentity
                return makeDocumentResult(
                    url: "https://example.com/b",
                    mainChildren: [[
                        "nodeId": 26,
                        "nodeType": 1,
                        "nodeName": "ARTICLE",
                        "localName": "article",
                        "nodeValue": "",
                        "attributes": ["id", "refreshed-after-loading-mutation"],
                        "childNodeCount": 0,
                        "children": [],
                    ]]
                )
            }
            return makeDocumentResult(
                url: "https://example.com/a",
                mainChildren: [[
                    "nodeId": 6,
                    "nodeType": 1,
                    "nodeName": "A",
                    "localName": "a",
                    "nodeValue": "",
                    "attributes": ["id", "first"],
                    "childNodeCount": 0,
                    "children": [],
                ]]
            )
        }
        inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady && inspector.document.node(nodeID: 6) != nil
        }
        #expect(initiallyReady)

        let firstContextID = try #require(inspector.testCurrentContextID)
        await inspector.testBeginFreshContext(
            documentURL: "https://example.com/b",
            targetIdentifier: nil,
            loadImmediately: false,
            isFreshDocument: true
        )
        inspector.testSetLoadingPhaseCurrentContext(targetIdentifier: "page-B")
        backend.emitPageEvent(
            method: "DOM.childNodeCountUpdated",
            params: [
                "nodeId": 16,
                "childNodeCount": 1,
            ],
            targetIdentifier: "page-B"
        )
        await backend.waitForPendingMessages()
        #expect(inspector.testHasDeferredLoadingMutationState)

        try await inspector.testRefreshCurrentDocumentFromTransport(
            targetIdentifier: "page-B",
            depth: 4,
            isFreshDocument: true
        )

        let refreshedAfterLoadingMutation = await waitForCondition {
            inspector.testIsReady
                && inspector.testCurrentContextID != firstContextID
                && inspector.testCurrentDocumentURL == "https://example.com/b"
                && pageBGetDocumentCallCount == 2
                && inspector.document.node(nodeID: 16) == nil
                && inspector.document.node(nodeID: 26) != nil
                && inspector.document.rootNode?.id.documentIdentity == identityBeforeFollowUpReplacement
                && inspector.testHasDeferredLoadingMutationState == false
        }
        #expect(refreshedAfterLoadingMutation)
    }

    @Test
    func repeatedReadyMessagesEventuallyHydrateCurrentRevision() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)

        #expect(inspector.testCurrentContextID == contextID)

    }

    @Test
    func readyContextRemainsCurrentWithoutPresentationReload() async throws {
        var getDocumentCallCount = 0
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                getDocumentCallCount += 1
                return makeDocumentResult(url: "https://example.com/a")
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        let initialGetDocumentCallCount = getDocumentCallCount

        #expect(inspector.testCurrentContextID == contextID)
        #expect(inspector.testCurrentDocumentURL == "https://example.com/a")
        #expect(getDocumentCallCount == initialGetDocumentCallCount)
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
                    inspectModePayload = runtimeTestDictionaryValue(payload["params"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
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
        #expect(runtimeTestHasVisibleHighlightConfig(
            runtimeTestDictionaryValue(inspectModePayload?["highlightConfig"])
        ))
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
                    let params = runtimeTestDictionaryValue(payload["params"])
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

#if canImport(UIKit)
    @Test
    func beginSelectionModeWaitsForSceneActivationBeforeEnablingInspectMode() async throws {
        let requester = FakeSceneActivationRequester()
        let targetScene = FakeSceneActivationTarget(activationState: .foregroundInactive)
        let requestGate = AsyncGate()
        let activationGate = AsyncGate()
        var inspectModePayload: [String: Any]?

        let previousRequester = WIDOMUIKitSceneActivationEnvironment.requester
        let previousSceneProvider = WIDOMUIKitSceneActivationEnvironment.sceneProvider
        let previousRequestingSceneProvider = WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider
        let previousActivationTimeout = WIDOMUIKitSceneActivationEnvironment.activationTimeout
        let previousActivationWaiter = WIDOMUIKitSceneActivationEnvironment.activationWaiter
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
            WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = previousRequestingSceneProvider
            WIDOMUIKitSceneActivationEnvironment.activationTimeout = previousActivationTimeout
            WIDOMUIKitSceneActivationEnvironment.activationWaiter = previousActivationWaiter
        }

        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in targetScene }
        WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = { _ in nil }
        WIDOMUIKitSceneActivationEnvironment.activationTimeout = .milliseconds(200)
        WIDOMUIKitSceneActivationEnvironment.activationWaiter = { target, timeout in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while target.activationState != .foregroundActive {
                if clock.now >= deadline {
                    throw DOMOperationError.scriptFailure("Page scene activation timed out.")
                }
                try await clock.sleep(for: .milliseconds(1))
            }
        }

        requester.onRequest = { _ in
            await requestGate.open()
            await activationGate.wait()
            targetScene.activationState = .foregroundActive
        }

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    inspectModePayload = runtimeTestDictionaryValue(payload["params"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        let window = hostWebViewInWindow(webView)
        defer { window.isHidden = true }

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let beginSelectionTask = Task {
            try await inspector.beginSelectionMode()
        }

        await requestGate.wait()
        #expect(inspectModePayload == nil)

        await activationGate.open()
        try await beginSelectionTask.value

        #expect(requester.requestCount == 1)
        #expect((inspectModePayload?["enabled"] as? Bool) == true)
        #expect(inspector.isSelectingElement)
    }

    @Test
    func selectionModeToggleCancelsPendingActivationBeforeInspectModeEnables() async throws {
#if canImport(UIKit)
        let requester = FakeSceneActivationRequester()
        let targetScene = FakeSceneActivationTarget(activationState: .foregroundInactive)
        let requestGate = AsyncGate()
        let activationGate = AsyncGate()
        var inspectModeEnabledValues: [Bool] = []

        let previousRequester = WIDOMUIKitSceneActivationEnvironment.requester
        let previousSceneProvider = WIDOMUIKitSceneActivationEnvironment.sceneProvider
        let previousRequestingSceneProvider = WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider
        let previousActivationTimeout = WIDOMUIKitSceneActivationEnvironment.activationTimeout
        let previousActivationWaiter = WIDOMUIKitSceneActivationEnvironment.activationWaiter
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
            WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = previousRequestingSceneProvider
            WIDOMUIKitSceneActivationEnvironment.activationTimeout = previousActivationTimeout
            WIDOMUIKitSceneActivationEnvironment.activationWaiter = previousActivationWaiter
        }

        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in targetScene }
        WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = { _ in nil }
        WIDOMUIKitSceneActivationEnvironment.activationTimeout = .milliseconds(200)
        WIDOMUIKitSceneActivationEnvironment.activationWaiter = { target, timeout in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while target.activationState != .foregroundActive {
                if clock.now >= deadline {
                    throw DOMOperationError.scriptFailure("Page scene activation timed out.")
                }
                try await clock.sleep(for: .milliseconds(1))
            }
        }

        requester.onRequest = { _ in
            await requestGate.open()
            await activationGate.wait()
            targetScene.activationState = .foregroundActive
        }

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        let window = hostWebViewInWindow(webView)
        defer { window.isHidden = true }

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.requestSelectionModeToggle()
        await requestGate.wait()
        #expect(inspector.isSelectingElement)
        #expect(inspectModeEnabledValues.isEmpty)

        inspector.requestSelectionModeToggle()
        let cancelled = await waitForCondition {
            inspector.isSelectingElement == false
        }
        #expect(cancelled)

        await activationGate.open()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(requester.requestCount == 1)
        #expect(inspectModeEnabledValues.contains(true) == false)
        #expect(inspector.isSelectingElement == false)
#endif
    }

    @Test
    func beginSelectionModeDoesNotEnableInspectModeWhenNavigationStartsDuringSceneActivation() async {
        let requester = FakeSceneActivationRequester()
        let targetScene = FakeSceneActivationTarget(activationState: .foregroundInactive)
        let requestGate = AsyncGate()
        let activationGate = AsyncGate()
        var inspectModePayload: [String: Any]?

        let previousRequester = WIDOMUIKitSceneActivationEnvironment.requester
        let previousSceneProvider = WIDOMUIKitSceneActivationEnvironment.sceneProvider
        let previousRequestingSceneProvider = WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider
        let previousActivationTimeout = WIDOMUIKitSceneActivationEnvironment.activationTimeout
        let previousActivationWaiter = WIDOMUIKitSceneActivationEnvironment.activationWaiter
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
            WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = previousRequestingSceneProvider
            WIDOMUIKitSceneActivationEnvironment.activationTimeout = previousActivationTimeout
            WIDOMUIKitSceneActivationEnvironment.activationWaiter = previousActivationWaiter
        }

        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in targetScene }
        WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = { _ in nil }
        WIDOMUIKitSceneActivationEnvironment.activationTimeout = .milliseconds(200)
        WIDOMUIKitSceneActivationEnvironment.activationWaiter = { target, timeout in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while target.activationState != .foregroundActive {
                if clock.now >= deadline {
                    throw DOMOperationError.scriptFailure("Page scene activation timed out.")
                }
                try await clock.sleep(for: .milliseconds(1))
            }
        }

        requester.onRequest = { _ in
            await requestGate.open()
            await activationGate.wait()
            targetScene.activationState = .foregroundActive
        }

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    inspectModePayload = runtimeTestDictionaryValue(payload["params"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        let window = hostWebViewInWindow(webView)
        defer { window.isHidden = true }

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let beginSelectionTask = Task {
            try await inspector.beginSelectionMode()
        }

        await requestGate.wait()
        inspector.testSetLoadingPhaseCurrentContext(targetIdentifier: "page-B")
        await activationGate.open()

        await #expect(throws: DOMOperationError.contextInvalidated) {
            try await beginSelectionTask.value
        }
        #expect(inspectModePayload == nil)
        #expect(inspector.isSelectingElement == false)
    }

    @Test
    func beginSelectionModeFailsWhenSceneActivationRequestErrors() async {
        let requester = FakeSceneActivationRequester()
        let targetScene = FakeSceneActivationTarget(activationState: .background)
        requester.requestError = NSError(
            domain: "WIDOMInspectorTests",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "scene activation failed"]
        )
        let previousRequester = WIDOMUIKitSceneActivationEnvironment.requester
        let previousSceneProvider = WIDOMUIKitSceneActivationEnvironment.sceneProvider
        let previousRequestingSceneProvider = WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider
        let previousActivationTimeout = WIDOMUIKitSceneActivationEnvironment.activationTimeout
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
            WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = previousRequestingSceneProvider
            WIDOMUIKitSceneActivationEnvironment.activationTimeout = previousActivationTimeout
        }

        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in targetScene }
        WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = { _ in nil }
        WIDOMUIKitSceneActivationEnvironment.activationTimeout = .milliseconds(100)

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
        let webView = makeTestWebView()
        let window = hostWebViewInWindow(webView)
        defer { window.isHidden = true }

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        await #expect(throws: DOMOperationError.scriptFailure("scene activation failed")) {
            try await inspector.beginSelectionMode()
        }
    }

    @Test
    func beginSelectionModeFailsWhenSceneActivationTimesOut() async {
        let requester = FakeSceneActivationRequester()
        let targetScene = FakeSceneActivationTarget(activationState: .background)
        let previousRequester = WIDOMUIKitSceneActivationEnvironment.requester
        let previousSceneProvider = WIDOMUIKitSceneActivationEnvironment.sceneProvider
        let previousRequestingSceneProvider = WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider
        let previousActivationTimeout = WIDOMUIKitSceneActivationEnvironment.activationTimeout
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
            WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = previousRequestingSceneProvider
            WIDOMUIKitSceneActivationEnvironment.activationTimeout = previousActivationTimeout
        }

        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in targetScene }
        WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = { _ in nil }
        WIDOMUIKitSceneActivationEnvironment.activationTimeout = .milliseconds(50)

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
        let webView = makeTestWebView()
        let window = hostWebViewInWindow(webView)
        defer { window.isHidden = true }

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        await #expect(throws: DOMOperationError.scriptFailure("Page scene activation timed out.")) {
            try await inspector.beginSelectionMode()
        }
    }

    @Test
    func beginSelectionModeDoesNotDependOnNativeInspectorPrivateAPIAvailability() async throws {
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
        }

        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, _ in true }

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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        await inspector.cancelSelectionMode()
    }

    @Test
    func beginSelectionModeUsesProtocolInspectModeWithoutNativeEnable() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var nodeSearchEnabledValues: [Bool] = []
        var operationOrder: [String] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        let previousPageEditingDismissalHandler = WIDOMUIKitInspectorSelectionEnvironment.pageEditingDismissalHandler
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
            WIDOMUIKitInspectorSelectionEnvironment.pageEditingDismissalHandler = previousPageEditingDismissalHandler
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in nil }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0
        WIDOMUIKitInspectorSelectionEnvironment.pageEditingDismissalHandler = { _ in
            operationOrder.append("dismissEditing")
        }

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    operationOrder.append("setInspectModeEnabled")
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(inspectModeEnabledValues == [true])
        #expect(nodeSearchEnabledValues.contains(true) == false)
        #expect(operationOrder.starts(with: ["dismissEditing", "setInspectModeEnabled"]))

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(inspectModeEnabledValues == [true, false])
        #expect(nodeSearchEnabledValues.contains(true) == false)
    }

    @Test
    func beginSelectionModeUsesNativeInspectorOnUIKitWhenPrivateInspectorIsAvailable() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var inspectModeHighlightConfigs: [[String: Any]?] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive.toggle()
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                        inspectModeHighlightConfigs.append(
                            runtimeTestDictionaryValue(params?["highlightConfig"])
                        )
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 0)
        #expect(nativeSelectionActive == false)
        #expect(nodeSearchEnabledValues.contains(true))
        #expect(inspectModeEnabledValues == [true])
        #expect(runtimeTestHasVisibleHighlightConfig(inspectModeHighlightConfigs.last ?? nil))

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(toggleCallCount == 0)
        #expect(nativeSelectionActive == false)
        #expect(nodeSearchEnabledValues.last == false)
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func beginSelectionModeDoesNotActivateNativeInspectorWhenNavigationStartsDuringProtocolEnable() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchEnabledValues: [Bool] = []
        var didInvalidateContext = false
        var inspector: WIDOMInspector!
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive.toggle()
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    guard let enabled = params?["enabled"] as? Bool else {
                        return [:]
                    }
                    inspectModeEnabledValues.append(enabled)
                    if enabled, didInvalidateContext == false {
                        didInvalidateContext = true
                        inspector.testSetLoadingPhaseCurrentContext(targetIdentifier: "page-B")
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        await #expect(throws: DOMOperationError.contextInvalidated) {
            try await inspector.beginSelectionMode()
        }
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 0)
        #expect(nativeSelectionActive == false)
        #expect(nodeSearchEnabledValues.isEmpty)
        #expect(inspectModeEnabledValues == [true, false])
        #expect(inspector.isSelectingElement == false)
    }

    @Test
    func beginSelectionModeDoesNotArmSelectionWhenProtocolEnableFailsWithStaleNativeNodeSearch() async throws {
        var inspectModeEnableAttempts = 0
        var connectCallCount = 0
        var toggleCallCount = 0
        var nodeSearchActive = true
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            return false
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            nodeSearchActive = enabled
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchActive
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if params?["enabled"] as? Bool == true {
                        inspectModeEnableAttempts += 1
                        throw DOMOperationError.scriptFailure("protocol unavailable")
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        do {
            try await inspector.beginSelectionMode()
            Issue.record("Expected selection mode activation to fail")
        } catch {}

        #expect(inspectModeEnableAttempts == 3)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 0)
        #expect(nodeSearchEnabledValues == [false, true, false])
        #expect(nodeSearchActive == false)
        #expect(inspector.isSelectingElement == false)
        #expect(
            inspector.inspectSelectionDiagnosticsForTesting.contains {
                if case .armed = $0 {
                    return true
                }
                return false
            } == false
        )
    }

    @Test
    func beginSelectionModeRetriesProtocolEnableAfterNativeInspectorWakeupOnUIKit() async throws {
        var inspectModeEnableAttempts = 0
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchActive = false
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive.toggle()
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            nodeSearchActive = enabled
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchActive
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in
            nodeSearchActive = false
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if params?["enabled"] as? Bool == true {
                        inspectModeEnableAttempts += 1
                        guard inspectModeEnableAttempts > 1, nodeSearchActive else {
                            throw DOMOperationError.scriptFailure("protocol unavailable")
                        }
                        inspectModeEnabledValues.append(true)
                    } else if params?["enabled"] as? Bool == false {
                        inspectModeEnabledValues.append(false)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(inspectModeEnableAttempts == 2)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 0)
        #expect(nodeSearchEnabledValues == [true, true])
        #expect(inspectModeEnabledValues == [true])

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(toggleCallCount == 0)
        #expect(nodeSearchEnabledValues == [true, true, false])
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func beginSelectionModeRefreshesActiveNativeNodeSearchAfterProtocolEnableOnUIKit() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchActive = true
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive.toggle()
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            nodeSearchActive = enabled
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchActive
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in
            nodeSearchActive = false
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                        nativeSelectionActive = enabled
                        nodeSearchActive = enabled
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 0)
        #expect(nodeSearchEnabledValues == [false, true])
        #expect(inspectModeEnabledValues == [true])

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(toggleCallCount == 1)
        #expect(nodeSearchEnabledValues == [false, true])
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func beginSelectionModeCancelsStaleNativeInspectModeBeforeRearmingOnUIKit() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchActive = false
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive.toggle()
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            nodeSearchActive = enabled
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchActive
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in
            nodeSearchActive = false
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        try await inspector.beginSelectionMode()

        #expect(inspector.isSelectingElement)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 0)
        #expect(nodeSearchEnabledValues == [true, false, true])
        #expect(inspectModeEnabledValues == [true, false, true])

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(nodeSearchEnabledValues == [true, false, true, false])
        #expect(inspectModeEnabledValues == [true, false, true, false])
    }

    @Test
    func beginSelectionModeKeepsNativeInspectorWhenActivationProbeIsUnavailableOnUIKit() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nil }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 1)
        #expect(nodeSearchEnabledValues == [true])
        #expect(inspectModeEnabledValues == [true])

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(toggleCallCount == 2)
        #expect(nodeSearchEnabledValues == [true, false])
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func beginSelectionModeFallsBackToTransportWhenNativeInspectorEnableFailsOnUIKit() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        let nativeSelectionActive = false
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            return false
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return false
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            false
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 1)
        #expect(nativeSelectionActive == false)
        #expect(nodeSearchEnabledValues.contains(true))
        #expect(inspectModeEnabledValues == [true])

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(toggleCallCount == 1)
        #expect(nativeSelectionActive == false)
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func beginSelectionModeFallsBackToTransportWhenNativeInspectorDoesNotActivateOnUIKit() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchEnabledValues: [Bool] = []
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive = false
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            false
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(
            using: backend,
            dependencies: .liveValue
        )
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        #expect(inspector.isSelectingElement)
        #expect(connectCallCount == 1)
        #expect(toggleCallCount == 1)
        #expect(nativeSelectionActive == false)
        #expect(nodeSearchEnabledValues.contains(true))
        #expect(inspectModeEnabledValues == [true])

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(toggleCallCount == 1)
        #expect(nativeSelectionActive == false)
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func selectionModeRearmsAfterFreshContextWithoutNativeEnable() async throws {
        var nodeSearchEnabledValues: [Bool] = []
        var documentVersion = 0
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in nil }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if documentVersion == 0 {
                        return makeDocumentResult(
                            url: "https://example.com/a",
                            mainChildren: [[
                                "nodeId": 6,
                                "nodeType": 1,
                                "nodeName": "A",
                                "localName": "a",
                                "nodeValue": "",
                                "attributes": ["id", "first"],
                                "childNodeCount": 0,
                                "children": [],
                            ]]
                        )
                    }
                    return makeDocumentResult(
                        url: "https://example.com/b",
                        mainChildren: [[
                            "nodeId": 16,
                            "nodeType": 1,
                            "nodeName": "SECTION",
                            "localName": "section",
                            "nodeValue": "",
                            "attributes": ["id", "second"],
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let initialSelection = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
        }
        #expect(initialSelection)

        documentVersion = 1
        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])
        let freshContextReady = await waitForCondition {
            inspector.testIsReady
                && inspector.testCurrentDocumentURL == "https://example.com/b"
                && inspector.document.selectedNode == nil
        }
        #expect(freshContextReady)

        inspector.resetInspectSelectionDiagnosticsForTesting()
        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 16])
        let reselectionReady = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 16 && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(
            inspector.inspectSelectionDiagnosticsForTesting.contains {
                if case let .armed(contextID, targetIdentifier, _) = $0 {
                    return contextID == inspector.testCurrentContextID
                        && !targetIdentifier.isEmpty
                }
                return false
            }
        )
        #expect(nodeSearchEnabledValues.contains(true) == false)
    }

    @Test
    func selectionModeRearmsAfterFreshContextWithTransportProtocolOnUIKit() async throws {
        var inspectModeEnabledValues: [Bool] = []
        var connectCallCount = 0
        var toggleCallCount = 0
        var nativeSelectionActive = false
        var nodeSearchEnabledValues: [Bool] = []
        var documentVersion = 0
        let previousPrivateInspectorAccessProvider = WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider
        let previousInspectorConnectedProvider = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider
        let previousInspectorConnector = WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector
        let previousElementSelectionToggler = WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        let previousTransportInspectActivationProvider = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider
        let previousTransportInspectActivationTimeout = WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = previousPrivateInspectorAccessProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = previousInspectorConnectedProvider
            WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = previousInspectorConnector
            WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = previousElementSelectionToggler
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = previousTransportInspectActivationProvider
            WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = previousTransportInspectActivationTimeout
        }

        WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider = { _ in
            connectCallCount > 0
        }
        WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector = { _ in
            connectCallCount += 1
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler = { _ in
            toggleCallCount += 1
            nativeSelectionActive.toggle()
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in
            nodeSearchEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in nativeSelectionActive }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider = { _ in
            inspectModeEnabledValues.last == true
        }
        WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds = 0

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if documentVersion == 0 {
                        return makeDocumentResult(
                            url: "https://example.com/a",
                            mainChildren: [[
                                "nodeId": 6,
                                "nodeType": 1,
                                "nodeName": "A",
                                "localName": "a",
                                "nodeValue": "",
                                "attributes": ["id", "first"],
                                "childNodeCount": 0,
                                "children": [],
                            ]]
                        )
                    }
                    return makeDocumentResult(
                        url: "https://example.com/b",
                        mainChildren: [[
                            "nodeId": 16,
                            "nodeType": 1,
                            "nodeName": "SECTION",
                            "localName": "section",
                            "nodeValue": "",
                            "attributes": ["id", "second"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let initialSelection = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
        }
        #expect(initialSelection)
        #expect(toggleCallCount == 0)
        #expect(nativeSelectionActive == false)
        #expect(nodeSearchEnabledValues.contains(true) == false)
        #expect(inspectModeEnabledValues == [true, false])

        documentVersion = 1
        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])
        let freshContextReady = await waitForCondition {
            inspector.testIsReady
                && inspector.testCurrentDocumentURL == "https://example.com/b"
                && inspector.document.selectedNode == nil
        }
        #expect(freshContextReady)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 16])
        let reselectionReady = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 16 && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(toggleCallCount == 0)
        #expect(nativeSelectionActive == false)
        #expect(connectCallCount == 0)
        #expect(nodeSearchEnabledValues.contains(true) == false)
        #expect(inspectModeEnabledValues == [true, false, true, false])
    }
#endif

    @Test
    func inspectNodeResolutionWaitsForReadyPhaseDuringNavigation() async throws {
        var requestedNodeIDs: [Int] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let nodeID = (params?["nodeId"] as? NSNumber)?.intValue
                        ?? runtimeTestIntValue(params?["nodeId"])
                    if let nodeID {
                        requestedNodeIDs.append(nodeID)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetLoadingPhaseCurrentContext(targetIdentifier: "page-A")

        let outcome = await inspector.testStartInspectNodeResolution(
            nodeID: 245,
            contextID: contextID,
            targetIdentifier: "page-A"
        )

        #expect(outcome == "waitingForMutation")
        #expect(requestedNodeIDs.isEmpty)
    }

    @Test
    func inspectNodeResolutionDoesNotRequestGenericCandidateChildNodes() async throws {
        var requestedNodeIDs: [Int] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let nodeID = params.flatMap({ runtimeTestIntValue($0["nodeId"]) }) {
                        requestedNodeIDs.append(nodeID)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)
        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    DOMGraphNodeDescriptor(
                        nodeID: 500,
                        nodeType: 1,
                        nodeName: "section",
                        localName: "section",
                        nodeValue: "",
                        attributes: [.init(name: "id", value: "dynamic")],
                        childCount: 2,
                        layoutFlags: [],
                        isRendered: true,
                        children: []
                    ),
                ]
            ),
            isFreshDocument: true
        )

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 502])
        await backend.waitForPendingMessages()
        #expect(requestedNodeIDs.isEmpty)

        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 500,
                "nodes": [[
                    "nodeId": 501,
                    "nodeType": 1,
                    "nodeName": "SPAN",
                    "localName": "span",
                    "nodeValue": "",
                    "attributes": ["id", "placeholder"],
                    "childNodeCount": 0,
                    "children": [],
                ]],
            ]
        )
        await backend.waitForPendingMessages()

        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.testHasInspectNodeResolution)
        #expect(inspector.document.errorMessage == nil)
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
    func domInspectSelectsRealTransportNode() async throws {
        var inspectModeEnabledValues: [Bool] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
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
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let enabled = params?["enabled"] as? Bool {
                        inspectModeEnabledValues.append(enabled)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(inspectModeEnabledValues == [true, false])
    }

    @Test
    func domInspectWaitsForQueuedPathEventsBeforeResolvingExactNode() async throws {
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
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 3,
                "nodes": [[
                    "nodeId": 6,
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

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.selectedNode?.nodeName == "a"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func domInspectConsumesRootScopePathEventsBeforeResolvingExactNode() async throws {
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
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(method: "DOM.inspect", params: ["nodeId": 6])
        backend.emitRootEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 3,
                "nodes": [[
                    "nodeId": 6,
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

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.selectedNode?.nodeName == "a"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
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
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
        }
        #expect(selected)
    }

    @Test
    func inspectorInspectDoesNotSelectDetachedRootPathWithoutCanonicalFrameDocument() async throws {
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                return makeDocumentResult(url: "https://example.com/a")
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-detached" {
                    backend.emitPageEvent(
                        method: "DOM.setChildNodes",
                        params: [
                            "nodes": [
                                [
                                    "nodeId": 9000,
                                    "nodeType": 9,
                                    "nodeName": "#document",
                                    "localName": "",
                                    "nodeValue": "",
                                    "documentURL": "https://ads.example.com/frame",
                                    "childNodeCount": 1,
                                    "children": [[
                                        "nodeId": 1093,
                                        "nodeType": 1,
                                        "nodeName": "IMG",
                                        "localName": "img",
                                        "nodeValue": "",
                                        "attributes": ["id", "detached-target"],
                                        "childNodeCount": 0,
                                        "children": [],
                                    ]],
                                ]
                            ]
                        ],
                        targetIdentifier: targetIdentifier
                    )
                    return ["nodeId": 1093]
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
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
                    "objectId": "node-object-detached",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode == nil
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.isSelectingElement == false
        }
        #expect(failed)
    }

    @Test
    func inspectorInspectKeepsDetachedTargetUnselectedWhenOnlyDetachedRootsArrive() async throws {
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                return makeDocumentResult(url: "https://example.com/a", bodyChildren: [])
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-detached-later-root" {
                    backend.emitPageEvent(
                        method: "DOM.setChildNodes",
                        params: [
                            "nodes": [[
                                "nodeId": 900,
                                "nodeType": 9,
                                "nodeName": "#document",
                                "localName": "",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 1093,
                                    "nodeType": 1,
                                    "nodeName": "IMG",
                                    "localName": "img",
                                    "nodeValue": "",
                                    "attributes": ["id", "detached-target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ]]
                        ],
                        targetIdentifier: targetIdentifier
                    )
                    backend.emitPageEvent(
                        method: "DOM.setChildNodes",
                        params: [
                            "nodes": [[
                                "nodeId": 910,
                                "nodeType": 9,
                                "nodeName": "#document",
                                "localName": "",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 2093,
                                    "nodeType": 1,
                                    "nodeName": "DIV",
                                    "localName": "div",
                                    "nodeValue": "",
                                    "attributes": ["id", "second-detached-target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ]]
                        ],
                        targetIdentifier: targetIdentifier
                    )
                    return ["nodeId": 1093]
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
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
                    "objectId": "node-object-detached-later-root",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode == nil
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.isSelectingElement == false
        }
        #expect(failed)
    }

    @Test
    func detachedRootEventsDoNotCompletePendingChildRequests() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a", bodyChildren: [])
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testRegisterPendingChildRequest(
            nodeID: 900,
            contextID: contextID,
            reportsToFrontend: true
        )

        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "nodes": [[
                    "nodeId": 900,
                    "nodeType": 9,
                    "nodeName": "#document",
                    "localName": "",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 1093,
                        "nodeType": 1,
                        "nodeName": "IMG",
                        "localName": "img",
                        "nodeValue": "",
                        "attributes": ["id", "detached-target"],
                        "childNodeCount": 0,
                        "children": [],
                    ]],
                ]]
            ]
        )

        let stillPending = await waitForCondition(
            maxAttempts: 20,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.testPendingChildRequestNodeIDs == [900]
        }
        #expect(stillPending)
    }

    @Test
    func inspectorInspectUsesFrameSourceTargetForRequestNode() async throws {
        var requestNodeTargets: [String] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if targetIdentifier == "frame-target-A" {
                        return [
                            "root": [
                                "nodeId": 24,
                                "nodeType": 9,
                                "nodeName": "#document",
                                "localName": "",
                                "nodeValue": "",
                                "documentURL": "https://example.com/frame",
                                "frameId": "frame-child",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 26,
                                    "nodeType": 1,
                                    "nodeName": "BUTTON",
                                    "localName": "button",
                                    "nodeValue": "",
                                    "attributes": ["id", "frame-target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ],
                        ]
                    }
                    return makeIFrameDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if params?["objectId"] as? String == "node-object-frame-target" {
                        requestNodeTargets.append(targetIdentifier)
                        return ["nodeId": 26]
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "frame-target-A",
                    "type": "frame",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "frame-target-A"
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 26 && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestNodeTargets == ["frame-target-A"])
    }

    @Test
    func inspectorInspectDoesNotProbeUnrelatedPageTargetsForRequestNode() async throws {
        var requestNodeTargets: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "page-frame-A" {
                    return [
                        "root": [
                            "nodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://ads.example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 241,
                                "nodeType": 1,
                                "nodeName": "HTML",
                                "localName": "html",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 260,
                                    "nodeType": 1,
                                    "nodeName": "BUTTON",
                                    "localName": "button",
                                    "nodeValue": "",
                                    "attributes": ["id", "frame-target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ]],
                        ],
                    ]
                }
                return makeIFrameDocumentResultWithEmptyNestedDocument(url: "https://example.com/a")
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-frame-target" {
                    requestNodeTargets.append(targetIdentifier)
                    if targetIdentifier == "page-frame-A" {
                        return ["nodeId": 260]
                    }
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-frame-A",
                    "type": "page",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "page-A"
        )

        let failed = await waitForCondition {
            inspector.document.selectedNode == nil
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.isSelectingElement == false
        }
        #expect(failed)
        #expect(requestNodeTargets == ["page-A"])
        let nestedDocument = try #require(inspector.document.node(nodeID: 24))
        #expect(nestedDocument.children.isEmpty)
        #expect(inspector.document.node(nodeID: 260) == nil)
    }

    @Test
    func domInspectSelectsNodeInsideContentDocument() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeIFrameDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let iframeNode = try #require(inspector.document.node(nodeID: 20))
        let nestedDocument = try #require(iframeNode.children.first)
        #expect(nestedDocument.nodeType == .document)
        #expect(nestedDocument.frameID == "frame-child")
        #expect(nestedDocument.parent?.nodeID == iframeNode.nodeID)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 26])

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 26
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "frame-target" }) == true
                && inspector.isSelectingElement == false
        }
        #expect(selected)
    }

    @Test
    func domInspectMaterializesUnloadedMainTreeAncestor() async throws {
        var requestedChildNodeIDs: [Int] = []
        var requestedDepths: [Int] = []
        var backend: FakeDOMTransportBackend!
        backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "SECTION",
                            "localName": "section",
                            "nodeValue": "",
                            "attributes": [],
                            "childNodeCount": 1,
                        ]]
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    let requestedDepth = params.flatMap {
                        runtimeTestIntValue($0["depth"]) ?? ($0["depth"] as? NSNumber)?.intValue
                    }
                    if let requestedNodeID {
                        requestedChildNodeIDs.append(requestedNodeID)
                    }
                    if let requestedDepth {
                        requestedDepths.append(requestedDepth)
                    }
                    if requestedNodeID == 10, requestedDepth == 128 {
                        backend.emitPageEvent(
                            method: "DOM.setChildNodes",
                            params: [
                                "parentId": 10,
                                "nodes": [[
                                    "nodeId": 26,
                                    "nodeType": 1,
                                    "nodeName": "BUTTON",
                                    "localName": "button",
                                    "nodeValue": "",
                                    "attributes": ["id", "materialized-target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ],
                            targetIdentifier: targetIdentifier
                        )
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 26])

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 26
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "materialized-target" }) == true
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestedChildNodeIDs == [10])
        #expect(requestedDepths == [128])
    }

    @Test
    func domInspectMaterializationContinuesPastTwelveUnloadedSiblings() async throws {
        var requestedChildNodeIDs: [Int] = []
        let unloadedSiblings = (10...22).map { nodeID in
            [
                "nodeId": nodeID,
                "nodeType": 1,
                "nodeName": "SECTION",
                "localName": "section",
                "nodeValue": "",
                "attributes": ["data-index", "\(nodeID)"],
                "childNodeCount": 1,
            ] as [String: Any]
        }
        var backend: FakeDOMTransportBackend!
        backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: unloadedSiblings
                    )
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    guard let requestedNodeID else {
                        return [:]
                    }
                    requestedChildNodeIDs.append(requestedNodeID)
                    let nodes: [[String: Any]]
                    if requestedNodeID == 22 {
                        nodes = [[
                            "nodeId": 260,
                            "nodeType": 1,
                            "nodeName": "BUTTON",
                            "localName": "button",
                            "nodeValue": "",
                            "attributes": ["id", "late-materialized-target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    } else {
                        nodes = []
                    }
                    backend.emitPageEvent(
                        method: "DOM.setChildNodes",
                        params: [
                            "parentId": requestedNodeID,
                            "nodes": nodes,
                        ],
                        targetIdentifier: targetIdentifier
                    )
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 260])

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 260
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "late-materialized-target" }) == true
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestedChildNodeIDs == Array(10...22))
    }

    @Test
    func domInspectMaterializesUnloadedSameTargetFrameDocument() async throws {
        var requestedChildNodeIDs: [Int] = []
        var backend: FakeDOMTransportBackend!
        backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    if let requestedNodeID {
                        requestedChildNodeIDs.append(requestedNodeID)
                        if requestedNodeID == 24 {
                            backend.emitPageEvent(
                                method: "DOM.setChildNodes",
                                params: [
                                    "parentId": 24,
                                    "nodes": [[
                                        "nodeId": 25,
                                        "nodeType": 1,
                                        "nodeName": "HTML",
                                        "localName": "html",
                                        "nodeValue": "",
                                        "childNodeCount": 1,
                                        "children": [[
                                            "nodeId": 26,
                                            "nodeType": 1,
                                            "nodeName": "BUTTON",
                                            "localName": "button",
                                            "nodeValue": "",
                                            "attributes": ["id", "frame-target"],
                                            "childNodeCount": 0,
                                            "children": [],
                                        ]],
                                    ]],
                                ],
                                targetIdentifier: targetIdentifier
                            )
                        }
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 20,
                        frameID: "frame-child",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: makeFrameDocumentDescriptor(
                            nodeID: 24,
                            frameID: "frame-child",
                            childCount: 1,
                            children: []
                        )
                    )
                ]
            ),
            isFreshDocument: false
        )

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 26])

        await backend.waitForPendingMessages()
        let resolved = await waitForCondition(maxAttempts: 120) {
            inspector.document.selectedNode?.nodeID == 26
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "frame-target" }) == true
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(resolved)
        #expect(requestedChildNodeIDs == [24])
    }

    @Test
    func inspectorInspectReplacesKnownNestedDocumentWithFrameTargetDocument() async throws {
        var requestNodeTargets: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "frame-target-A" {
                    return [
                        "root": [
                            "nodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 241,
                                "nodeType": 1,
                                "nodeName": "HTML",
                                "localName": "html",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 260,
                                    "nodeType": 1,
                                    "nodeName": "BUTTON",
                                    "localName": "button",
                                    "nodeValue": "",
                                    "attributes": ["id", "frame-target"],
                                    "childNodeCount": 0,
                                    "children": [],
                                ]],
                            ]],
                        ],
                    ]
                }
                return makeIFrameDocumentResultWithEmptyNestedDocument(url: "https://example.com/a")
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-frame-target" {
                    requestNodeTargets.append(targetIdentifier)
                    return ["nodeId": 260]
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "frame-target-A",
                    "type": "frame",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "frame-target-A"
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 260
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "frame-target" }) == true
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(inspector.document.selectedNode?.nodeID != 20)
        #expect(requestNodeTargets == ["frame-target-A"])
        let frameOwner = try #require(inspector.document.node(nodeID: 20))
        let frameTargetDocument = try #require(frameOwner.contentDocument)
        #expect(frameTargetDocument.nodeID == 240)
        #expect(frameTargetDocument.targetIdentifier == "frame-target-A")
        #expect(frameTargetDocument.children.first?.nodeID == 241)
        #expect(inspector.document.node(nodeID: 24) == nil)
        #expect(inspector.document.node(nodeID: 260)?.nodeID == 260)
    }

    @Test
    func inspectorInspectAttachesFrameTargetDocumentWhenOwnerHasNoContentDocument() async throws {
        var requestNodeTargets: [String] = []
        var highlightTargets: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "frame-target-A" {
                    return [
                        "root": [
                            "nodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 260,
                                "nodeType": 1,
                                "nodeName": "BUTTON",
                                "localName": "button",
                                "nodeValue": "",
                                "attributes": ["id", "frame-target"],
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                        ],
                    ]
                }
                return makeDocumentResult(
                    url: "https://example.com/a",
                    mainChildren: [[
                        "nodeId": 20,
                        "nodeType": 1,
                        "nodeName": "IFRAME",
                        "localName": "iframe",
                        "nodeValue": "",
                        "attributes": ["id", "frame-owner"],
                        "frameId": "frame-child",
                        "childNodeCount": 0,
                        "children": [],
                    ]]
                )
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.highlightNode:
                highlightTargets.append(targetIdentifier)
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-frame-target" {
                    requestNodeTargets.append(targetIdentifier)
                    return ["nodeId": 260]
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "frame-target-A",
                    "type": "frame",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "frame-target-A"
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 260
                && inspector.document.selectedNode?.targetIdentifier == "frame-target-A"
                && highlightTargets.contains("frame-target-A")
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestNodeTargets == ["frame-target-A"])
        #expect(highlightTargets.last == "frame-target-A")
        let frameOwner = try #require(inspector.document.node(nodeID: 20))
        #expect(frameOwner.contentDocument?.nodeID == 240)
        #expect(frameOwner.contentDocument?.targetIdentifier == "frame-target-A")
    }

    @Test
    func inspectorInspectMaterializesUnloadedFrameTargetDocumentRoot() async throws {
        var requestNodeTargets: [String] = []
        var requestedChildNodes: [(targetIdentifier: String, nodeID: Int)] = []
        var backend: FakeDOMTransportBackend!
        backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "frame-target-A" {
                    return [
                        "root": [
                            "nodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                        ],
                    ]
                }
                return makeDocumentResult(
                    url: "https://example.com/a",
                    mainChildren: [[
                        "nodeId": 20,
                        "nodeType": 1,
                        "nodeName": "IFRAME",
                        "localName": "iframe",
                        "nodeValue": "",
                        "attributes": ["id", "frame-owner"],
                        "frameId": "frame-child",
                        "childNodeCount": 0,
                        "children": [],
                    ]]
                )
            case WITransportMethod.DOM.setInspectModeEnabled,
                 WITransportMethod.DOM.highlightNode:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-frame-target" {
                    requestNodeTargets.append(targetIdentifier)
                    return ["nodeId": 260]
                }
                return [:]
            case WITransportMethod.DOM.requestChildNodes:
                let params = runtimeTestDictionaryValue(payload["params"])
                let requestedNodeID = params.flatMap {
                    runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                }
                if let requestedNodeID {
                    requestedChildNodes.append((targetIdentifier, requestedNodeID))
                }
                if targetIdentifier == "frame-target-A", requestedNodeID == 240 {
                    backend.emitPageEvent(
                        method: "DOM.setChildNodes",
                        params: [
                            "parentId": 240,
                            "nodes": [[
                                "nodeId": 260,
                                "nodeType": 1,
                                "nodeName": "BUTTON",
                                "localName": "button",
                                "nodeValue": "",
                                "attributes": ["id", "frame-target"],
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                        ],
                        targetIdentifier: targetIdentifier
                    )
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "frame-target-A",
                    "type": "frame",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "frame-target-A"
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 260
                && inspector.document.selectedNode?.targetIdentifier == "frame-target-A"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestNodeTargets == ["frame-target-A"])
        #expect(requestedChildNodes.count == 1)
        #expect(requestedChildNodes.first?.targetIdentifier == "frame-target-A")
        #expect(requestedChildNodes.first?.nodeID == 240)
    }

    @Test
    func inspectorInspectAttachesFrameTargetDocumentForFrameOwnerElement() async throws {
        var requestNodeTargets: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "frame-target-A" {
                    return [
                        "root": [
                            "nodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 260,
                                "nodeType": 1,
                                "nodeName": "BUTTON",
                                "localName": "button",
                                "nodeValue": "",
                                "attributes": ["id", "frame-target"],
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                        ],
                    ]
                }
                return makeDocumentResult(
                    url: "https://example.com/a",
                    mainChildren: [[
                        "nodeId": 20,
                        "nodeType": 1,
                        "nodeName": "FRAME",
                        "localName": "frame",
                        "nodeValue": "",
                        "attributes": ["id", "frame-owner"],
                        "frameId": "frame-child",
                        "childNodeCount": 0,
                        "children": [],
                    ]]
                )
            case WITransportMethod.DOM.setInspectModeEnabled,
                 WITransportMethod.DOM.highlightNode:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if params?["objectId"] as? String == "node-object-frame-target" {
                    requestNodeTargets.append(targetIdentifier)
                    return ["nodeId": 260]
                }
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "frame-target-A",
                    "type": "frame",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "frame-target-A"
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 260
                && inspector.document.selectedNode?.targetIdentifier == "frame-target-A"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestNodeTargets == ["frame-target-A"])
        let frameOwner = try #require(inspector.document.node(nodeID: 20))
        #expect(frameOwner.contentDocument?.nodeID == 240)
        #expect(frameOwner.contentDocument?.targetIdentifier == "frame-target-A")
    }

    @Test
    func laterInspectCallbacksAreIgnoredAfterFirstBackendHit() async throws {
        var requestedObjectIDs: [String] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
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
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if let objectID = params?["objectId"] as? String {
                        requestedObjectIDs.append(objectID)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "bad-node-object",
                ],
                "hints": [:],
            ]
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestedObjectIDs.isEmpty)
    }

    @Test
    func inspectorInspectWaitsForRequestNodeSideEffectEventsBeforeResolvingExactNode() async throws {
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
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.selectedNode?.nodeName == "a"
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func inspectorInspectMaterializesAttachedIncompleteAncestorWhenRequestNodeReturnsUnresolvedNode() async throws {
        var requestedChildNodeIDs: [Int] = []
        var backend: FakeDOMTransportBackend!
        backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    return ["nodeId": 341]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    if let requestedNodeID {
                        requestedChildNodeIDs.append(requestedNodeID)
                        if requestedNodeID == 20 {
                            backend.emitPageEvent(
                                method: "DOM.setChildNodes",
                                params: [
                                    "parentId": 20,
                                    "nodes": [[
                                        "nodeId": 341,
                                        "nodeType": 1,
                                        "nodeName": "SPAN",
                                        "localName": "span",
                                        "nodeValue": "",
                                        "attributes": ["id", "resolved-target"],
                                        "childNodeCount": 0,
                                        "children": [],
                                    ]],
                                ],
                                targetIdentifier: targetIdentifier
                            )
                        }
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    DOMGraphNodeDescriptor(
                        nodeID: 20,
                        nodeType: 1,
                        nodeName: "DIV",
                        localName: "div",
                        nodeValue: "",
                        attributes: [.init(name: "id", value: "incomplete-container")],
                        childCount: 1,
                        layoutFlags: [],
                        isRendered: true,
                        children: []
                    ),
                ]
            ),
            isFreshDocument: true
        )

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-908",
                ],
                "hints": [:],
            ]
        )

        let resolved = await waitForCondition(maxAttempts: 120) {
            requestedChildNodeIDs == [20]
                && inspector.document.selectedNode?.nodeID == 341
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "resolved-target" }) == true
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(resolved)
    }

    @Test
    func inspectorInspectDoesNotRequestChildNodesWhenNoAttachedIncompleteCandidatesExist() async throws {
        var requestedChildNodeIDs: [Int] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    return ["nodeId": 908]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    if let requestedNodeID {
                        requestedChildNodeIDs.append(requestedNodeID)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    DOMGraphNodeDescriptor(
                        nodeID: 20,
                        nodeType: 1,
                        nodeName: "DIV",
                        localName: "div",
                        nodeValue: "",
                        attributes: [.init(name: "id", value: "loaded-container")],
                        childCount: 0,
                        layoutFlags: [],
                        isRendered: true,
                        children: []
                    ),
                ]
            ),
            isFreshDocument: true
        )

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-908",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            requestedChildNodeIDs.isEmpty
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.selectedNode == nil
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.isSelectingElement == false
        }
        #expect(failed)
    }

    @Test
    func pendingChildRequestClearsWhenReloadStartsFreshContext() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let initialContextID = try #require(inspector.testCurrentContextID)
        inspector.testRegisterPendingChildRequest(
            nodeID: 3,
            contextID: initialContextID,
            reportsToFrontend: true
        )

        #expect(inspector.testPendingChildRequestNodeIDs == [3])

        try await inspector.reloadDocument()

        let cleared = await waitForCondition {
            inspector.testPendingChildRequestNodeIDs.isEmpty
                && inspector.testCurrentContextID != initialContextID
        }
        #expect(cleared)
    }

    @Test
    func childRequestCompletesImmediatelyWhenRequestedSubtreeIsAlreadyLoaded() async throws {
        var requestedNodeIDs: [Int] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    if let requestedNodeID {
                        requestedNodeIDs.append(requestedNodeID)
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testHandleInspectorMessage(
            .requestChildren(nodeID: 3, depth: 1, contextID: contextID)
        )

        let completedImmediately = await waitForCondition(
            maxAttempts: 10,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.testPendingChildRequestNodeIDs.isEmpty
        }
        #expect(completedImmediately)
        #expect(requestedNodeIDs.isEmpty)
    }

    @Test
    func inspectorInspectResolutionFailureSurfacesErrorAndAllowsRetry() async throws {
        var requestedObjectIDs: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, _ in
            switch method {
            case WITransportMethod.DOM.getDocument:
                return makeDocumentResult(
                    url: "https://example.com/a",
                    bodyChildren: []
                )
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                let objectID = params?["objectId"] as? String
                if let objectID {
                    requestedObjectIDs.append(objectID)
                }
                if objectID == "bad-node-object" {
                    return [:]
                }
                return ["nodeId": 6]
            default:
                return [:]
            }
        }

        let inspector = makeInspector(using: backend)
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
                    "objectId": "bad-node-object",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition {
            requestedObjectIDs.contains("bad-node-object")
                && inspector.isSelectingElement == false
                && inspector.document.selectedNode == nil
                && inspector.document.errorMessage == "Failed to resolve selected element."
        }
        #expect(failed)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 3,
                "nodes": [[
                    "nodeId": 6,
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
        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.selectedNode?.nodeName == "a"
                && inspector.document.errorMessage == nil
        }
        #expect(selected)
    }

    @Test
    func laterInspectorInspectCallbacksAreIgnoredWhileDOMInspectResolutionIsPending() async throws {
        var requestedObjectIDs: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, _ in
            switch method {
            case WITransportMethod.DOM.getDocument:
                return makeDocumentResult(
                    url: "https://example.com/a",
                    bodyChildren: []
                )
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            case WITransportMethod.DOM.requestNode:
                let params = runtimeTestDictionaryValue(payload["params"])
                if let objectID = params?["objectId"] as? String {
                    requestedObjectIDs.append(objectID)
                }
                return ["nodeId": 6]
            default:
                return [:]
            }
        }

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

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

        let ignoredLaterInspectCallback = await waitForCondition {
            requestedObjectIDs.isEmpty
        }
        #expect(ignoredLaterInspectCallback)

        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 3,
                "nodes": [[
                    "nodeId": 6,
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

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.selectedNode?.nodeName == "a"
                && inspector.document.errorMessage == nil
        }
        #expect(selected)
        #expect(requestedObjectIDs.isEmpty)
    }

    @Test
    func frontendSelectionAppliesWhenNoInspectResolutionIsPending() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSeedInspectNodeResolution(
            nodeID: 3,
            contextID: contextID,
            outstandingNodeIDs: []
        )

        let competingSelection = DOMSelectionSnapshotPayload(
            nodeID: 3,
            attributes: [],
            path: ["html", "body"],
            selectorPath: "body",
            styleRevision: 0
        )
        inspector.testHandleInspectorSelection(competingSelection)

        #expect(inspector.document.selectedNode?.nodeID == 3)
        #expect(inspector.testHasInspectNodeResolution == false)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func frontendSelectionRefinesPendingInspectResolutionWhenDifferentNodeArrives() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        bodyChildren: [[
                            "nodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["id", "refined"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                default:
                    return [:]
                }
            }
        )

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSeedInspectNodeResolution(
            nodeID: 3,
            contextID: contextID,
            outstandingNodeIDs: []
        )

        inspector.testHandleInspectorSelection(
            DOMSelectionSnapshotPayload(
                nodeID: 6,
                attributes: [DOMAttribute(nodeId: 6, name: "id", value: "refined")],
                path: ["html", "body", "a"],
                selectorPath: "#refined",
                styleRevision: 0
            )
        )

        let refined = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "refined" }) == true
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.errorMessage == nil
        }
        #expect(refined)
    }

    @Test
    func frontendSelectionDoesNotOverrideCurrentSelectionWhilePendingInspectResolutionExists() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        bodyChildren: [[
                            "nodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["id", "refined"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                default:
                    return [:]
                }
            }
        )

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        let existingNode = try #require(inspector.document.rootNode?.children.first)
        inspector.document.applySelectionSnapshot(
            .init(
                nodeID: existingNode.nodeID,
                attributes: existingNode.attributes,
                path: [existingNode.localName],
                selectorPath: existingNode.localName,
                styleRevision: existingNode.styleRevision
            )
        )
        inspector.testSeedInspectNodeResolution(
            nodeID: 3,
            contextID: contextID,
            outstandingNodeIDs: []
        )

        inspector.testHandleInspectorSelection(
            DOMSelectionSnapshotPayload(
                nodeID: 6,
                attributes: [DOMAttribute(nodeId: 6, name: "id", value: "refined")],
                path: ["html", "body", "a"],
                selectorPath: "#refined",
                styleRevision: 0
            )
        )

        #expect(inspector.document.selectedNode?.nodeID == existingNode.nodeID)
        #expect(inspector.testHasInspectNodeResolution)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func unresolvedInspectDoesNotTreatPreviousSelectionAsSuccess() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if params?["objectId"] as? String == "node-object-missing" {
                        return ["nodeId": 999]
                    }
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    throw WITransportError.remoteError(
                        scope: .page,
                        method: WITransportMethod.DOM.requestChildNodes,
                        message: "child request failed"
                    )
                default:
                    return [:]
                }
            }
        )

        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let existingNode = try #require(inspector.document.node(nodeID: 4))
        inspector.document.applySelectionSnapshot(
            .init(
                nodeID: existingNode.nodeID,
                attributes: existingNode.attributes,
                path: ["html", "body", "main"],
                selectorPath: "#root",
                styleRevision: existingNode.styleRevision
            )
        )
        #expect(inspector.document.selectedNode?.nodeID == 4)

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-missing",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 4
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.testHasInspectNodeResolution == false
                && inspector.isSelectingElement == false
        }
        #expect(failed)
    }

    @Test
    func pendingInspectResolutionSurvivesEmptyFrameOwnerSetChildNodesAndResolvesInsideContentDocument() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 800,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: makeFrameDocumentDescriptor(
                            nodeID: 801,
                            frameID: "frame-owner",
                            childCount: 0,
                            children: []
                        )
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSeedInspectNodeResolution(
            nodeID: 928,
            contextID: contextID,
            outstandingNodeIDs: [801],
            scopedRootNodeIDs: [801]
        )

        let htmlNode = DOMGraphNodeDescriptor(
            nodeID: 951,
            nodeType: 1,
            nodeName: "HTML",
            localName: "html",
            nodeValue: "",
            attributes: [],
            childCount: 1,
            layoutFlags: [],
            isRendered: true,
            children: [
                DOMGraphNodeDescriptor(
                    nodeID: 955,
                    nodeType: 1,
                    nodeName: "BODY",
                    localName: "body",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            nodeID: 928,
                            frameID: "frame-owner",
                            nodeType: 1,
                            nodeName: "IMG",
                            localName: "img",
                            nodeValue: "",
                            attributes: [.init(name: "id", value: "frame-target")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            ]
        )

        await inspector.testHandleMutationBundleThroughTransportPath(
            .init(
                events: [
                    .setChildNodes(parentNodeID: 800, nodes: []),
                    .setChildNodes(parentNodeID: 801, nodes: [htmlNode])
                ]
            ),
            contextID: contextID
        )

        let selectedNode = try #require(inspector.document.selectedNode)
        #expect(selectedNode.nodeID == 928)
        #expect(selectedNode.parent?.nodeID == 955)
        #expect(inspector.testHasInspectNodeResolution == false)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func pendingInspectResolutionSurvivesEmptyFrameOwnerSetChildNodesWhenNodeTypesAreMissing() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    DOMGraphNodeDescriptor(
                        nodeID: 800,
                        frameID: "frame-owner",
                        nodeType: 0,
                        nodeName: "IFRAME",
                        localName: "iframe",
                        nodeValue: "",
                        attributes: [.init(name: "id", value: "frame-owner")],
                        childCount: 1,
                        layoutFlags: [],
                        isRendered: true,
                        contentDocument: DOMGraphNodeDescriptor(
                            nodeID: 801,
                            frameID: "frame-owner",
                            nodeType: 0,
                            nodeName: "#document",
                            localName: "",
                            nodeValue: "",
                            attributes: [],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSeedInspectNodeResolution(
            nodeID: 928,
            contextID: contextID,
            outstandingNodeIDs: [801],
            scopedRootNodeIDs: [801]
        )

        let htmlNode = DOMGraphNodeDescriptor(
            nodeID: 951,
            nodeType: 0,
            nodeName: "HTML",
            localName: "html",
            nodeValue: "",
            attributes: [],
            childCount: 1,
            layoutFlags: [],
            isRendered: true,
            children: [
                DOMGraphNodeDescriptor(
                    nodeID: 955,
                    nodeType: 0,
                    nodeName: "BODY",
                    localName: "body",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            nodeID: 928,
                            frameID: "frame-owner",
                            nodeType: 0,
                            nodeName: "IMG",
                            localName: "img",
                            nodeValue: "",
                            attributes: [.init(name: "id", value: "frame-target")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            ]
        )

        await inspector.testHandleMutationBundleThroughTransportPath(
            .init(
                events: [
                    .setChildNodes(parentNodeID: 800, nodes: []),
                    .setChildNodes(parentNodeID: 801, nodes: [htmlNode])
                ]
            ),
            contextID: contextID
        )

        let selectedNode = try #require(inspector.document.selectedNode)
        #expect(selectedNode.nodeID == 928)
        #expect(selectedNode.parent?.nodeID == 955)
        #expect(inspector.testHasInspectNodeResolution == false)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func pendingInspectResolutionDoesNotSelectIframeOwnerWhenScopedResolutionIsUnresolved() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 774,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: makeFrameDocumentDescriptor(
                            nodeID: 775,
                            frameID: "frame-owner",
                            childCount: 1,
                            children: []
                        )
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSeedInspectNodeResolution(
            nodeID: 999,
            contextID: contextID,
            outstandingNodeIDs: [775],
            scopedRootNodeIDs: [775]
        )

        let htmlNode = DOMGraphNodeDescriptor(
            nodeID: 956,
            nodeType: 1,
            nodeName: "HTML",
            localName: "html",
            nodeValue: "",
            attributes: [],
            childCount: 1,
            layoutFlags: [],
            isRendered: true,
            children: [
                DOMGraphNodeDescriptor(
                    nodeID: 958,
                    nodeType: 1,
                    nodeName: "BODY",
                    localName: "body",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            nodeID: 959,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            ]
        )

        await inspector.testApplyMutationBundleAndResolveInspectNodeIfPossible(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(parentNodeID: 775, nodes: [htmlNode])
                ]
            ),
            contextID: contextID
        )

        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.selectedNode?.nodeID != 774)
        #expect(inspector.testHasInspectNodeResolution)
        #expect(inspector.testPendingInspectScopedResolutionRootNodeIDs == [775])
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func pendingInspectResolutionResolvesExactNodeFromUnknownParentSetChildNodesEvent() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 774,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: makeFrameDocumentDescriptor(
                            nodeID: 775,
                            frameID: "frame-owner",
                            childCount: 1,
                            children: []
                        )
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSeedInspectNodeResolution(
            nodeID: 7574,
            contextID: contextID,
            outstandingNodeIDs: [],
            scopedRootNodeIDs: [775]
        )

        await inspector.testHandleMutationBundleThroughTransportPath(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(
                        parentNodeID: 7572,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                nodeID: 7573,
                                nodeType: 1,
                                nodeName: "HTML",
                                localName: "html",
                                nodeValue: "",
                                attributes: [],
                                childCount: 1,
                                layoutFlags: [],
                                isRendered: true,
                                children: [
                                    DOMGraphNodeDescriptor(
                                        nodeID: 7575,
                                        nodeType: 1,
                                        nodeName: "BODY",
                                        localName: "body",
                                        nodeValue: "",
                                        attributes: [],
                                        childCount: 1,
                                        layoutFlags: [],
                                        isRendered: true,
                                        children: [
                                            DOMGraphNodeDescriptor(
                                                nodeID: 7574,
                                                nodeType: 1,
                                                nodeName: "IMG",
                                                localName: "img",
                                                nodeValue: "",
                                                attributes: [.init(name: "src", value: "https://example.com/ad.png")],
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
                    )
                ]
            ),
            contextID: contextID
        )

        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.node(nodeID: 7574) == nil)
        #expect(inspector.testHasInspectNodeResolution)
        #expect(inspector.document.errorMessage == nil)
        #expect(inspector.document.topLevelRoots().map(\.nodeID) == [1])
    }

    @Test
    func inspectorInspectFailsWhenRequestNodeResolvesOnlyDetachedNode() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if params?["objectId"] as? String == "detached-node-object" {
                        return ["nodeId": 664]
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        await inspector.testHandleMutationBundleThroughTransportPath(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(
                        parentNodeID: 646,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                nodeID: 647,
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                nodeValue: "",
                                attributes: [],
                                childCount: 1,
                                layoutFlags: [],
                                isRendered: true,
                                children: []
                            )
                        ]
                    ),
                    .setChildNodes(
                        parentNodeID: 647,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                nodeID: 664,
                                nodeType: 1,
                                nodeName: "VIDEO",
                                localName: "video",
                                nodeValue: "",
                                attributes: [.init(name: "id", value: "detached-video")],
                                childCount: 0,
                                layoutFlags: [],
                                isRendered: true,
                                children: []
                            )
                        ]
                    ),
                ]
            ),
            contextID: contextID
        )

        #expect(inspector.document.node(nodeID: 664) == nil)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "detached-node-object",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode == nil
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.node(nodeID: 664) == nil
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.isSelectingElement == false
        }
        #expect(failed)
    }

    @Test
    func inspectorInspectFailsWhenOnlyDetachedFrameDocumentMutationArrives() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.setInspectModeEnabled:
                    return [:]
                case WITransportMethod.DOM.requestNode:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    if params?["objectId"] as? String == "detached-node-object" {
                        return ["nodeId": 664]
                    }
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 774,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: makeFrameDocumentDescriptor(
                            nodeID: 775,
                            frameID: "frame-owner",
                            childCount: 1,
                            children: []
                        )
                    )
                ]
            ),
            isFreshDocument: true
        )

        try await inspector.beginSelectionMode()
        backend.emitRootEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "detached-node-object",
                ],
                "hints": [:],
            ]
        )

        let contextID = try #require(inspector.testCurrentContextID)
        await inspector.testHandleMutationBundleThroughTransportPath(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(
                        parentNodeID: 646,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                nodeID: 647,
                                nodeType: 1,
                                nodeName: "HTML",
                                localName: "html",
                                nodeValue: "",
                                attributes: [],
                                childCount: 1,
                                layoutFlags: [],
                                isRendered: true,
                                children: [
                                    DOMGraphNodeDescriptor(
                                        nodeID: 648,
                                        nodeType: 1,
                                        nodeName: "BODY",
                                        localName: "body",
                                        nodeValue: "",
                                        attributes: [],
                                        childCount: 1,
                                        layoutFlags: [],
                                        isRendered: true,
                                        children: [
                                            DOMGraphNodeDescriptor(
                                                nodeID: 664,
                                                nodeType: 1,
                                                nodeName: "IMG",
                                                localName: "img",
                                                nodeValue: "",
                                                attributes: [.init(name: "id", value: "detached-image")],
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
                    )
                ]
            ),
            contextID: contextID
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode == nil
                && inspector.testHasInspectNodeResolution == false
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.document.topLevelRoots().map(\.nodeID) == [1]
        }
        #expect(failed)

        #expect(inspector.document.node(nodeID: 775)?.nodeID == 775)
        #expect(inspector.document.node(nodeID: 664) == nil)
    }

    @Test
    func frontendSnapshotDoesNotInjectDetachedSelectionSubtreeIntoMainRoot() async throws {
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        await inspector.testHandleMutationBundleThroughTransportPath(
            DOMGraphMutationBundle(
                events: [
                    .setDetachedRoots(
                        nodes: [
                            DOMGraphNodeDescriptor(
                                nodeID: 647,
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
                                        nodeID: 664,
                                        nodeType: 1,
                                        nodeName: "CANVAS",
                                        localName: "canvas",
                                        nodeValue: "",
                                        attributes: [],
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
            contextID: contextID
        )

        let detachedNode = try #require(inspector.document.node(nodeID: 664))
        inspector.document.applySelectionSnapshot(
            .init(
                nodeID: detachedNode.nodeID,
                attributes: detachedNode.attributes,
                path: [],
                selectorPath: nil,
                styleRevision: detachedNode.styleRevision
            )
        )

        #expect(inspector.testDocumentRootNodeID == 1)
        #expect(inspector.testDocumentRootChildNodeIDs.contains(647) == false)
        #expect(inspector.document.topLevelRoots().map(\.nodeID) == [1])
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.isSelectingElement == false
        }
        #expect(selected)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 999])
        let preserved = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(cssSelector: "#title")

        #expect(inspector.document.selectedNode?.nodeID == 6)
        #expect(inspector.document.selectedNode?.selectorPath == "#title")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func selectNodeForTestingRequestsCurrentDocumentSubtreeForSelector() async throws {
        var requestedNodeIDs: [Int] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
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
                    if requestedNodeIDs.contains(3) || requestedNodeIDs.contains(1) {
                        return ["nodeId": 6]
                    }
                    return [:]
                case WITransportMethod.DOM.requestChildNodes:
                    if let params = runtimeTestDictionaryValue(payload["params"]) {
                        let nodeID = (params["nodeId"] as? NSNumber)?.intValue
                            ?? runtimeTestIntValue(params["nodeId"])
                        if let nodeID {
                            requestedNodeIDs.append(nodeID)
                        }
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(cssSelector: "h1")

        #expect(inspector.document.selectedNode?.nodeID == 6)
        #expect(inspector.document.selectedNode?.selectorPath == "h1")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func selectNodeForTestingResolvesSelectorInsideContentDocument() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeIFrameDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.querySelector:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let nodeID = (params?["nodeId"] as? NSNumber)?.intValue
                        ?? runtimeTestIntValue(params?["nodeId"])
                    let selector = params?["selector"] as? String
                    if nodeID == 24, selector == "#frame-target" {
                        return ["nodeId": 26]
                    }
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(cssSelector: "#frame-target")

        #expect(inspector.document.selectedNode?.nodeID == 26)
        #expect(inspector.document.selectedNode?.selectorPath == "#frame-target")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func copySelectedSelectorPathGeneratesPathLocally() async throws {
        let inspector = WIDOMInspector()
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData(makeDocumentResult(url: "https://example.com/a")),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }
        inspector.document.replaceDocument(
            with: .init(root: snapshot.root, selectedNodeID: 5),
            isFreshDocument: true
        )

        let selectorPath = try await inspector.copySelectedSelectorPath()
        let xpath = try await inspector.copySelectedXPath()

        #expect(selectorPath == "#target")
        #expect(xpath == "/html/body/main/div")
    }

    @Test
    func copySelectedSelectorPathIncludesFrameOwnerForNestedDocument() async throws {
        let inspector = WIDOMInspector()
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            await normalizer.normalizeDocumentResponseData(
                jsonData(makeIFrameDocumentResult(url: "https://example.com/a")),
                resetDocument: true
            )
        )
        guard case let .snapshot(snapshot, _) = delta else {
            Issue.record("Expected DOM snapshot")
            return
        }
        inspector.document.replaceDocument(
            with: .init(root: snapshot.root, selectedNodeID: 26),
            isFreshDocument: true
        )

        let selectorPath = try await inspector.copySelectedSelectorPath()
        let xpath = try await inspector.copySelectedXPath()

        #expect(selectorPath == "#frame-owner > html > #frame-target")
        #expect(xpath == "/html/body/main/iframe/html/button")
    }

    @Test
    func copyNodeByModelIDRoutesHTMLToNodeTarget() async throws {
        var requestedTargetIdentifier: String?
        var requestedNodeID: Int?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getOuterHTML:
                    requestedTargetIdentifier = targetIdentifier
                    requestedNodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"])
                    return ["outerHTML": "<span id=\"frame-target\"></span>"]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        let frameTargetNode = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 260,
            nodeType: 1,
            nodeName: "SPAN",
            localName: "span",
            nodeValue: "",
            attributes: [.init(name: "id", value: "frame-target")],
            regularChildCount: 0,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: []
        )
        let frameDocument = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 240,
            frameID: "frame-child",
            nodeType: 9,
            nodeName: "#document",
            localName: "",
            nodeValue: "",
            attributes: [],
            regularChildCount: 1,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: [frameTargetNode]
        )
        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 24,
                        frameID: "frame-child",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: frameDocument
                    )
                ]
            ),
            isFreshDocument: true
        )

        let node = try #require(inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 260)))
        let html = try await inspector.copyNode(nodeID: node.id, kind: .html)

        #expect(requestedTargetIdentifier == "frame-target-A")
        #expect(requestedNodeID == 260)
        #expect(html == "<span id=\"frame-target\"></span>")
    }

    @Test
    func deleteNodeByModelIDRoutesToNodeTarget() async throws {
        var requestedTargetIdentifier: String?
        var requestedNodeID: Int?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.removeNode:
                    requestedTargetIdentifier = targetIdentifier
                    requestedNodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        let frameTargetNode = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 260,
            nodeType: 1,
            nodeName: "SPAN",
            localName: "span",
            nodeValue: "",
            attributes: [.init(name: "id", value: "frame-target")],
            regularChildCount: 0,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: []
        )
        let frameDocument = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 240,
            frameID: "frame-child",
            nodeType: 9,
            nodeName: "#document",
            localName: "",
            nodeValue: "",
            attributes: [],
            regularChildCount: 1,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: [frameTargetNode]
        )
        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 24,
                        frameID: "frame-child",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: frameDocument
                    )
                ]
            ),
            isFreshDocument: true
        )

        let node = try #require(inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 260)))
        try await inspector.deleteNode(nodeID: node.id, undoManager: nil)

        #expect(requestedTargetIdentifier == "frame-target-A")
        #expect(requestedNodeID == 260)
        #expect(inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 260)) == nil)
    }

    @Test
    func hideNodeHighlightRoutesToHighlightedFrameTarget() async throws {
        var commandCalls: [(method: String, targetIdentifier: String, nodeID: Int?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                let params = runtimeTestDictionaryValue(payload["params"])
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.highlightNode:
                    commandCalls.append((
                        method,
                        targetIdentifier,
                        runtimeTestIntValue(params?["nodeId"])
                    ))
                    return [:]
                case WITransportMethod.DOM.hideHighlight:
                    commandCalls.append((method, targetIdentifier, nil))
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        let frameTargetNode = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 260,
            nodeType: 1,
            nodeName: "SPAN",
            localName: "span",
            nodeValue: "",
            attributes: [.init(name: "id", value: "frame-target")],
            regularChildCount: 0,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: []
        )
        let frameDocument = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 240,
            frameID: "frame-child",
            nodeType: 9,
            nodeName: "#document",
            localName: "",
            nodeValue: "",
            attributes: [],
            regularChildCount: 1,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: [frameTargetNode]
        )
        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 24,
                        frameID: "frame-child",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: frameDocument
                    )
                ]
            ),
            isFreshDocument: true
        )

        let node = try #require(inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 260)))
        await inspector.highlightNode(node, reveal: false)
        await inspector.hideNodeHighlight()

        #expect(commandCalls.contains {
            $0.method == WITransportMethod.DOM.highlightNode
                && $0.targetIdentifier == "frame-target-A"
                && $0.nodeID == 260
        })
        let hideHighlightCall = commandCalls.last {
            $0.method == WITransportMethod.DOM.hideHighlight
        }
        #expect(hideHighlightCall?.targetIdentifier == "frame-target-A")
    }

    @Test
    func undoDeleteOfFrameNodeRefreshesFrameSubtreeWithoutReplacingPageDocument() async throws {
        var commandCalls: [(method: String, targetIdentifier: String, nodeID: Int?)] = []
        var pageDocumentRequestCount = 0
        var frameDocumentRequestCount = 0
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            let params = runtimeTestDictionaryValue(payload["params"])
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "frame-target-A" {
                    frameDocumentRequestCount += 1
                    return [
                        "root": [
                            "nodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 260,
                                "nodeType": 1,
                                "nodeName": "BUTTON",
                                "localName": "button",
                                "nodeValue": "",
                                "attributes": ["id", "frame-target"],
                                "childNodeCount": 0,
                                "children": [],
                            ]],
                        ],
                    ]
                }
                pageDocumentRequestCount += 1
                return makeIFrameDocumentResultWithEmptyNestedDocument(url: "https://example.com/a")
            case WITransportMethod.DOM.requestNode:
                if params?["objectId"] as? String == "node-object-frame-target" {
                    commandCalls.append((method, targetIdentifier, nil))
                    return ["nodeId": 260]
                }
                return [:]
            case WITransportMethod.DOM.removeNode,
                 WITransportMethod.DOM.undo,
                 WITransportMethod.DOM.redo,
                 WITransportMethod.DOM.highlightNode:
                commandCalls.append((
                    method,
                    targetIdentifier,
                    runtimeTestIntValue(params?["nodeId"])
                ))
                return [:]
            case WITransportMethod.DOM.setInspectModeEnabled:
                return [:]
            default:
                return [:]
            }
        }
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "frame-target-A",
                    "type": "frame",
                    "isProvisional": false,
                ],
            ]
        )
        await backend.waitForPendingMessages()

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(
            method: "Inspector.inspect",
            params: [
                "object": [
                    "type": "object",
                    "subtype": "node",
                    "objectId": "node-object-frame-target",
                ],
                "hints": [:],
            ],
            targetIdentifier: "frame-target-A"
        )

        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 260
                && inspector.document.selectedNode?.targetIdentifier == "frame-target-A"
                && inspector.isSelectingElement == false
        }
        #expect(selected)

        let undoManager = UndoManager()
        try await inspector.deleteSelection(undoManager: undoManager)

        let deleted = await waitForCondition {
            commandCalls.contains {
                $0.method == WITransportMethod.DOM.removeNode
                    && $0.targetIdentifier == "frame-target-A"
                    && $0.nodeID == 260
            }
                && inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 260)) == nil
        }
        #expect(deleted)

        undoManager.undo()

        let undone = await waitForCondition(maxAttempts: 120) {
            commandCalls.contains {
                $0.method == WITransportMethod.DOM.undo
                    && $0.targetIdentifier == "frame-target-A"
            }
                && inspector.document.rootNode?.targetIdentifier == runtimeDOMTestDefaultTargetIdentifier
                && inspector.document.rootNode?.nodeID == 1
                && inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 260)) != nil
        }
        #expect(undone)
        let frameOwner = try #require(inspector.document.node(nodeID: 20))
        #expect(frameOwner.contentDocument?.nodeID == 240)
        #expect(frameOwner.contentDocument?.targetIdentifier == "frame-target-A")
        #expect(inspector.document.node(nodeID: 24) == nil)
        #expect(pageDocumentRequestCount == 1)
        #expect(frameDocumentRequestCount == 2)
    }

    @Test
    func setAttributeUsesTargetScopedNodeID() async throws {
        var requestedNodeID: Int?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com")
                case WITransportMethod.DOM.setAttributeValue:
                    requestedNodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeElementDescriptor(
                        nodeID: 7,
                        localName: "section",
                        idAttribute: "target"
                    ),
                ]
            ),
            isFreshDocument: true
        )

        let nodeID = try #require(inspector.document.node(nodeID: 7)?.id)
        try await inspector.setAttribute(nodeID: nodeID, name: "data-test", value: "1")

        #expect(requestedNodeID == 7)
    }

    @Test
    func attributeMutationsUseMergedNodeTargetIdentifier() async throws {
        var requests: [(method: String, targetIdentifier: String, nodeID: Int)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, targetIdentifier in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com")
                case WITransportMethod.DOM.setAttributeValue, WITransportMethod.DOM.removeAttribute:
                    let nodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"]) ?? 0
                    requests.append((method, targetIdentifier, nodeID))
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        let frameTargetButton = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 26,
            nodeType: .element,
            nodeName: "BUTTON",
            localName: "button",
            nodeValue: "",
            attributes: [.init(name: "id", value: "frame-target")],
            regularChildCount: 0,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: []
        )
        let frameTargetDocument = DOMGraphNodeDescriptor(
            targetIdentifier: "frame-target-A",
            nodeID: 24,
            frameID: "frame-child",
            nodeType: .document,
            nodeName: "#document",
            localName: "",
            nodeValue: "",
            attributes: [],
            regularChildCount: 1,
            regularChildrenAreLoaded: true,
            layoutFlags: [],
            isRendered: true,
            regularChildren: [frameTargetButton]
        )
        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        nodeID: 20,
                        frameID: "frame-child",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        contentDocument: frameTargetDocument
                    )
                ]
            ),
            isFreshDocument: true
        )

        let nodeID = try #require(inspector.document.node(key: .init(targetIdentifier: "frame-target-A", nodeID: 26))?.id)
        try await inspector.setAttribute(nodeID: nodeID, name: "data-test", value: "1")
        try await inspector.removeAttribute(nodeID: nodeID, name: "data-test")

        #expect(requests.map(\.targetIdentifier) == ["frame-target-A", "frame-target-A"])
        #expect(requests.map(\.nodeID) == [26, 26])
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

        #expect(inspector.document.selectedNode?.nodeID == 4)
        #expect(inspector.document.selectedNode?.selectorPath == "main")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func selectNodeForTestingPreviewWaitsForRequestedChildNodesBeforeFallbackResolution() async throws {
        var didRequestChildNodes = false
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/a",
                            "childNodeCount": 1,
                            "children": [],
                        ]
                    ]
                case WITransportMethod.DOM.requestChildNodes:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    let requestedNodeID = params.flatMap {
                        runtimeTestIntValue($0["nodeId"]) ?? ($0["nodeId"] as? NSNumber)?.intValue
                    }
                    didRequestChildNodes = requestedNodeID == 1
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let selectionTask = Task {
            try await inspector.selectNodeForTesting(
                preview: "<h1>",
                selectorPath: "h1"
            )
        }

        let requested = await waitForCondition {
            didRequestChildNodes && inspector.document.selectedNode == nil
        }
        #expect(requested)

        backend.emitPageEvent(
            method: "DOM.setChildNodes",
            params: [
                "parentId": 1,
                "nodes": [[
                    "nodeId": 2,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "attributes": [],
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 3,
                        "nodeType": 1,
                        "nodeName": "BODY",
                        "localName": "body",
                        "nodeValue": "",
                        "attributes": [],
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 6,
                            "nodeType": 1,
                            "nodeName": "H1",
                            "localName": "h1",
                            "nodeValue": "",
                            "attributes": ["id", "title"],
                            "childNodeCount": 0,
                            "children": [],
                        ]],
                    ]],
                ]],
            ]
        )

        try await selectionTask.value

        #expect(inspector.document.selectedNode?.nodeID == 6)
        #expect(inspector.document.selectedNode?.selectorPath == "h1")
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        inspector.document.applySelectionSnapshot(
            .init(
                nodeID: 4,
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
        #expect(inspector.document.errorMessage == "Failed to resolve selected element.")
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
                    let params = runtimeTestDictionaryValue(payload["params"])
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
            inspector.document.selectedNode?.nodeID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestedObjectIDs.contains("node-object-pending"))
    }

    @Test
    func selectedNodeSendsPersistentHighlightAndHidesItOnDocumentReload() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?, highlightConfig: [String: Any]?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let params = runtimeTestDictionaryValue(payload["params"])
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled {
                    inspectModeEnabled = params?["enabled"] as? Bool
                } else {
                    inspectModeEnabled = nil
                }
                let highlightConfig: [String: Any]?
                if method == WITransportMethod.DOM.highlightNode {
                    highlightConfig = runtimeTestDictionaryValue(params?["highlightConfig"])
                } else {
                    highlightConfig = nil
                }
                pageCalls.append((
                    method: method,
                    inspectModeEnabled: inspectModeEnabled,
                    highlightConfig: highlightConfig
                ))
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let selected = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6
                && inspector.isSelectingElement == false
                && pageCalls.contains(where: { $0.method == WITransportMethod.DOM.highlightNode })
        }
        #expect(selected)

        let inspectModeDisableIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.setInspectModeEnabled && $0.inspectModeEnabled == false
        })
        let persistentHighlightIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.highlightNode
        })
        #expect(inspectModeDisableIndex != nil)
        #expect(persistentHighlightIndex != nil)
        if let inspectModeDisableIndex, let persistentHighlightIndex {
            #expect(persistentHighlightIndex > inspectModeDisableIndex)
            #expect(runtimeTestHasVisibleHighlightConfig(pageCalls[persistentHighlightIndex].highlightConfig))
        }

        try await inspector.reloadDocument()

        let reloaded = await waitForCondition {
            inspector.document.selectedNode == nil
        }
        #expect(reloaded)
        let highlightIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.highlightNode
        })
        let hideHighlightIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.hideHighlight
        })
        #expect(highlightIndex != nil)
        #expect(hideHighlightIndex != nil)
        if let highlightIndex, let hideHighlightIndex {
            #expect(hideHighlightIndex > highlightIndex)
        }
    }

    @Test
    func frontendHoverHighlightPreservesRevealFalse() async throws {
        var lastHighlightReveal: Bool?
        var lastHighlightConfig: [String: Any]?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.highlightNode:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    lastHighlightReveal = params?["reveal"] as? Bool
                    lastHighlightConfig = runtimeTestDictionaryValue(params?["highlightConfig"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testCurrentContextID != nil
                && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testHandleInspectorMessage(.highlight(nodeID: 6, reveal: false, contextID: contextID))

        let sentRevealFalse = await waitForCondition {
            lastHighlightReveal == false
        }
        #expect(sentRevealFalse)
        #expect(runtimeTestHasVisibleHighlightConfig(lastHighlightConfig))
    }

    @Test
    func snapshotReloadMessageRefreshesCurrentDocumentFromTransport() async throws {
        var currentURL = "https://example.com/a"
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.DOM.getDocument else {
                    return [:]
                }
                return makeDocumentResult(url: currentURL)
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady
                && inspector.document.rootNode != nil
                && inspector.testCurrentDocumentURL == "https://example.com/a"
        }
        #expect(ready)

        currentURL = "https://example.com/b"
        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testHandleInspectorMessage(.requestSnapshotReload(reason: "dom-sync", contextID: contextID))

        let reloaded = await waitForCondition {
            inspector.testCurrentDocumentURL == "https://example.com/b"
        }
        #expect(reloaded)
    }

    @Test
    func successfulInspectReappliesPersistentHighlightAfterInspectModeTeardown() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?, highlightConfig: [String: Any]?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let params = runtimeTestDictionaryValue(payload["params"])
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled {
                    inspectModeEnabled = params?["enabled"] as? Bool
                } else {
                    inspectModeEnabled = nil
                }
                let highlightConfig: [String: Any]?
                if method == WITransportMethod.DOM.highlightNode {
                    highlightConfig = runtimeTestDictionaryValue(params?["highlightConfig"])
                } else {
                    highlightConfig = nil
                }
                pageCalls.append((
                    method: method,
                    inspectModeEnabled: inspectModeEnabled,
                    highlightConfig: highlightConfig
                ))

                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
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
            return inspector.document.selectedNode?.nodeID == 6
                && inspector.isSelectingElement == false
                && highlightIndex >= 0
        }
        #expect(selected)
        let persistentHighlightIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.highlightNode
        })
        #expect(persistentHighlightIndex != nil)
        if let persistentHighlightIndex {
            #expect(runtimeTestHasVisibleHighlightConfig(pageCalls[persistentHighlightIndex].highlightConfig))
        }
    }

    @Test
    func unresolvedInspectRestoresExistingPersistentHighlight() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?, highlightConfig: [String: Any]?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let params = runtimeTestDictionaryValue(payload["params"])
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled {
                    inspectModeEnabled = params?["enabled"] as? Bool
                } else {
                    inspectModeEnabled = nil
                }
                let highlightConfig: [String: Any]?
                if method == WITransportMethod.DOM.highlightNode {
                    highlightConfig = runtimeTestDictionaryValue(params?["highlightConfig"])
                } else {
                    highlightConfig = nil
                }
                pageCalls.append((
                    method: method,
                    inspectModeEnabled: inspectModeEnabled,
                    highlightConfig: highlightConfig
                ))

                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])
        let initialSelection = await waitForCondition {
            inspector.document.selectedNode?.nodeID == 6 && inspector.isSelectingElement == false
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
            return inspector.document.selectedNode?.nodeID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
                && highlightIndex >= 0
        }
        #expect(preserved)
        let restoredHighlightIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.highlightNode
        })
        #expect(restoredHighlightIndex != nil)
        if let restoredHighlightIndex {
            #expect(runtimeTestHasVisibleHighlightConfig(pageCalls[restoredHighlightIndex].highlightConfig))
        }
    }

    @Test
    func inspectorInspectResolvesNodeBeforeInspectModeTeardown() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?, highlightConfig: [String: Any]?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let params = runtimeTestDictionaryValue(payload["params"])
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled {
                    inspectModeEnabled = params?["enabled"] as? Bool
                } else {
                    inspectModeEnabled = nil
                }
                let highlightConfig: [String: Any]?
                if method == WITransportMethod.DOM.highlightNode {
                    highlightConfig = runtimeTestDictionaryValue(params?["highlightConfig"])
                } else {
                    highlightConfig = nil
                }
                pageCalls.append((
                    method: method,
                    inspectModeEnabled: inspectModeEnabled,
                    highlightConfig: highlightConfig
                ))

                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        mainChildren: [[
                            "nodeId": 6,
                            "nodeType": 1,
                            "nodeName": "A",
                            "localName": "a",
                            "nodeValue": "",
                            "attributes": ["href", "/target"],
                            "childNodeCount": 0,
                            "children": [],
                        ]]
                    )
                case WITransportMethod.DOM.requestNode:
                    return ["nodeId": 6]
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
            inspector.document.selectedNode?.nodeID == 6
                && inspector.isSelectingElement == false
                && inspector.document.errorMessage == nil
        }
        #expect(selected)

        let requestNodeIndex = pageCalls.lastIndex(where: { $0.method == WITransportMethod.DOM.requestNode })
        let disableInspectIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.setInspectModeEnabled && $0.inspectModeEnabled == false
        })
        let persistentHighlightIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.highlightNode
        })
        #expect(requestNodeIndex != nil)
        #expect(disableInspectIndex != nil)
        if let requestNodeIndex, let disableInspectIndex {
            #expect(requestNodeIndex < disableInspectIndex)
        }
        #expect(persistentHighlightIndex != nil)
        if let disableInspectIndex, let persistentHighlightIndex {
            #expect(persistentHighlightIndex > disableInspectIndex)
            #expect(runtimeTestHasVisibleHighlightConfig(pageCalls[persistentHighlightIndex].highlightConfig))
        }
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
                            "nodeType": 1,
                            "nodeName": "MAIN",
                            "localName": "main",
                            "nodeValue": "",
                            "attributes": ["id", "root"],
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 5,
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
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        #expect(inspector.document.node(nodeID: 90) == nil)
        let bodyNode = inspector.document.node(nodeID: 3)
        #expect(bodyNode?.childCount == 1)
        #expect(bodyNode?.children.count == 1)
    }
}

@MainActor
private func makeInspector(
    using backend: FakeDOMTransportBackend,
    derivedPageTargetIdentifier: String? = nil,
    dependencies: WIInspectorDependencies? = nil
) -> WIDOMInspector {
    let dependencies = dependencies ?? makeDOMInspectorTestDependencies()
    let sharedTransport = WISharedInspectorTransport(sessionFactory: {
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
#if DEBUG
        if let derivedPageTargetIdentifier {
            session.derivedPageTargetIdentifierProviderForTesting = { _ in
                derivedPageTargetIdentifier
            }
        }
#endif
        return session
    })
    return WIDOMInspector(
        dependencies: dependencies,
        sharedTransport: sharedTransport
    )
}

@MainActor
private func makeDOMInspectorTestDependencies() -> WIInspectorDependencies {
    var dependencies = WIInspectorDependencies.liveValue
    dependencies.webKitSPI = .testValue
    return dependencies
}

@MainActor
private func makeTestWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: .zero, configuration: configuration)
}

#if canImport(UIKit)
@MainActor
private func hostWebViewInWindow(_ webView: WKWebView) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let viewController = UIViewController()
    viewController.view.frame = window.bounds
    webView.frame = viewController.view.bounds
    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    viewController.view.addSubview(webView)
    window.rootViewController = viewController
    window.isHidden = false
    return window
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else {
            return
        }

        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard isOpen == false else {
            return
        }

        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
#endif

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

private func waitForCondition(
    maxAttempts: Int = 200,
    intervalNanoseconds: UInt64 = 20_000_000,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<maxAttempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return await condition()
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [])
}

private func makeDocumentResult(
    url: String,
    bodyChildren: [[String: Any]]? = nil,
    mainChildren: [[String: Any]]? = nil
) -> [String: Any] {
    let resolvedMainChildren = mainChildren ?? [[
        "nodeId": 5,
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
            "nodeType": 9,
            "nodeName": "#document",
            "localName": "",
            "nodeValue": "",
            "documentURL": url,
            "childNodeCount": 1,
            "children": [
                [
                    "nodeId": 2,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [
                        [
                            "nodeId": 3,
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

private func makeIFrameDocumentResult(url: String) -> [String: Any] {
    makeDocumentResult(
        url: url,
        mainChildren: [[
            "nodeId": 20,
            "nodeType": 1,
            "nodeName": "IFRAME",
            "localName": "iframe",
            "nodeValue": "",
            "attributes": ["id", "frame-owner"],
            "frameId": "frame-child",
            "childNodeCount": 1,
            "contentDocument": [
                "nodeId": 24,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "documentURL": "https://example.com/frame",
                "frameId": "frame-child",
                "childNodeCount": 1,
                "children": [[
                    "nodeId": 25,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 26,
                        "nodeType": 1,
                        "nodeName": "BUTTON",
                        "localName": "button",
                        "nodeValue": "",
                        "attributes": ["id", "frame-target"],
                        "childNodeCount": 0,
                        "children": [],
                    ]],
                ]],
            ],
        ]]
    )
}

private func makeIFrameDocumentResultWithEmptyNestedDocument(url: String) -> [String: Any] {
    makeDocumentResult(
        url: url,
        mainChildren: [[
            "nodeId": 20,
            "nodeType": 1,
            "nodeName": "IFRAME",
            "localName": "iframe",
            "nodeValue": "",
            "attributes": ["id", "frame-owner"],
            "frameId": "frame-child",
            "childNodeCount": 1,
            "contentDocument": [
                "nodeId": 24,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "documentURL": "https://example.com/frame",
                "frameId": "frame-child",
                "childNodeCount": 0,
                "children": [],
            ],
        ]]
    )
}

private func makeMainDocumentSnapshot(
    mainChildren: [DOMGraphNodeDescriptor]
) -> DOMGraphSnapshot {
    DOMGraphSnapshot(
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
                    nodeName: "html",
                    localName: "html",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            nodeID: 3,
                            nodeType: 1,
                            nodeName: "body",
                            localName: "body",
                            nodeValue: "",
                            attributes: [],
                            childCount: 1,
                            layoutFlags: [],
                            isRendered: true,
                            children: [
                                DOMGraphNodeDescriptor(
                                    nodeID: 4,
                                    nodeType: 1,
                                    nodeName: "main",
                                    localName: "main",
                                    nodeValue: "",
                                    attributes: [],
                                    childCount: mainChildren.count,
                                    layoutFlags: [],
                                    isRendered: true,
                                    children: mainChildren
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    )
}

private func makeFrameOwnerDescriptor(
    nodeID: UInt64,
    frameID: String,
    idAttribute: String,
    titleAttribute: String? = nil,
    childCount: Int,
    contentDocument: DOMGraphNodeDescriptor? = nil,
    children: [DOMGraphNodeDescriptor] = []
) -> DOMGraphNodeDescriptor {
    var attributes = [DOMAttribute(name: "id", value: idAttribute)]
    if let titleAttribute {
        attributes.append(.init(name: "title", value: titleAttribute))
    }
    return DOMGraphNodeDescriptor(
        nodeID: nodeID,
        frameID: frameID,
        nodeType: 1,
        nodeName: "iframe",
        localName: "iframe",
        nodeValue: "",
        attributes: attributes,
        childCount: childCount,
        layoutFlags: [],
        isRendered: true,
        children: children,
        contentDocument: contentDocument
    )
}

private func makeElementDescriptor(
    nodeID: UInt64,
    localName: String,
    idAttribute: String? = nil,
    children: [DOMGraphNodeDescriptor] = []
) -> DOMGraphNodeDescriptor {
    var attributes: [DOMAttribute] = []
    if let idAttribute {
        attributes.append(.init(name: "id", value: idAttribute))
    }
    return DOMGraphNodeDescriptor(
        nodeID: nodeID,
        nodeType: 1,
        nodeName: localName.uppercased(),
        localName: localName,
        nodeValue: "",
        attributes: attributes,
        childCount: children.count,
        layoutFlags: [],
        isRendered: true,
        children: children
    )
}

private func makeFrameDocumentDescriptor(
    nodeID: UInt64,
    frameID: String,
    childCount: Int,
    children: [DOMGraphNodeDescriptor] = []
) -> DOMGraphNodeDescriptor {
    DOMGraphNodeDescriptor(
        nodeID: nodeID,
        frameID: frameID,
        nodeType: 9,
        nodeName: "#document",
        localName: "",
        nodeValue: "",
        attributes: [],
        childCount: childCount,
        layoutFlags: [],
        isRendered: true,
        children: children
    )
}

private func runtimeTestIntValue(_ value: Any?) -> Int? {
    if value is Bool {
        return nil
    }
    if let value = value as? Int {
        return value
    }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return nil
        }
        return value.intValue
    }
    return nil
}

private func runtimeTestDictionaryValue(_ value: Any?) -> [String: Any]? {
    if let value = value as? [String: Any] {
        return value
    }
    if let value = value as? NSDictionary {
        var normalized: [String: Any] = [:]
        for (key, entry) in value {
            if let stringKey = key as? String {
                normalized[stringKey] = entry
            } else if let stringKey = key as? NSString {
                normalized[String(stringKey)] = entry
            }
        }
        return normalized.isEmpty ? nil : normalized
    }
    return nil
}

private func runtimeTestDoubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Float {
        return Double(value)
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? NSNumber {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return nil
        }
        return value.doubleValue
    }
    return nil
}

private func runtimeTestHasVisibleHighlightConfig(_ config: [String: Any]?) -> Bool {
    guard let config else {
        return false
    }
    return ["contentColor", "paddingColor", "borderColor", "marginColor"].allSatisfy { key in
        guard let color = runtimeTestDictionaryValue(config[key]) else {
            return false
        }
        return runtimeTestDoubleValue(color["a"]).map { $0 > 0 } == true
    }
}

@MainActor
private final class FakeDOMTransportBackend: WITransportPlatformBackend {
    var supportSnapshot: WITransportSupportSnapshot
    var pageResultProvider: ((String, [String: Any], String) throws -> [String: Any])?
    var attachError: Error?
    private(set) var attachCount = 0

    private var messageSink: (any WITransportBackendMessageSink)?
    private var currentTargetIdentifier = "page-A"
    private let emitsInitialPageTargetCreatedOnAttach: Bool

    init(
        capabilities: Set<WITransportCapability> = [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain],
        emitsInitialPageTargetCreatedOnAttach: Bool = true,
        pageResultProvider: ((String, [String: Any], String) throws -> [String: Any])? = nil
    ) {
        self.supportSnapshot = .supported(
            backendKind: .macOSNativeInspector,
            capabilities: capabilities
        )
        self.emitsInitialPageTargetCreatedOnAttach = emitsInitialPageTargetCreatedOnAttach
        self.pageResultProvider = pageResultProvider
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        if let attachError {
            throw attachError
        }
        attachCount += 1
        self.messageSink = messageSink
        if emitsInitialPageTargetCreatedOnAttach {
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(currentTargetIdentifier)","type":"page","isProvisional":false}}}"#
            )
            await messageSink.waitForPendingMessages()
        }
    }

    func detach() {
        messageSink = nil
    }

    func sendRootMessage(_ message: String) throws {
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
        if method == WITransportMethod.DOM.enable {
            return Data("{}".utf8)
        }
        return nil
    }

    func waitForPendingMessages() async {
        await messageSink?.waitForPendingMessages()
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

@MainActor
private var runtimeTestPendingScopedRootNodeIDsByInspector: [ObjectIdentifier: [UInt64]] = [:]

private let runtimeDOMTestDefaultTargetIdentifier = "page-A"

private func runtimeDOMTestKey(_ nodeID: UInt64) -> DOMNodeKey {
    DOMNodeKey(targetIdentifier: runtimeDOMTestDefaultTargetIdentifier, nodeID: Int(nodeID))
}

@MainActor
private func runtimeDOMTestFirstNode(with nodeID: Int, in roots: [DOMNodeModel]) -> DOMNodeModel? {
    for root in roots {
        if root.nodeID == nodeID {
            return root
        }
        if let match = runtimeDOMTestFirstNode(with: nodeID, in: root.ownedChildren) {
            return match
        }
    }
    return nil
}

private func == (lhs: DOMNodeKey, rhs: UInt64) -> Bool {
    lhs.nodeID == Int(rhs)
}

private func == (lhs: UInt64, rhs: DOMNodeKey) -> Bool {
    rhs == lhs
}

private func == (lhs: DOMNodeKey, rhs: Int) -> Bool {
    lhs.nodeID == rhs
}

private func == (lhs: Int, rhs: DOMNodeKey) -> Bool {
    rhs == lhs
}

private extension DOMPayloadNormalizer {
    func normalizeDocumentResponseData(
        _ data: Data,
        resetDocument: Bool
    ) -> DOMGraphDelta? {
        normalizeDocumentResponseData(
            data,
            targetIdentifier: runtimeDOMTestDefaultTargetIdentifier,
            resetDocument: resetDocument
        )
    }

    func normalizeDOMEvent(
        method: String,
        paramsData: Data
    ) -> DOMGraphDelta? {
        normalizeDOMEvent(
            method: method,
            targetIdentifier: runtimeDOMTestDefaultTargetIdentifier,
            paramsData: paramsData
        )
    }
}

private extension DOMGraphSnapshot {
    init(root: DOMGraphNodeDescriptor, selectedNodeID: UInt64?) {
        self.init(
            root: root,
            selectedKey: selectedNodeID.map(runtimeDOMTestKey)
        )
    }
}

private extension DOMGraphNodeDescriptor {
    init(
        nodeID: UInt64,
        frameID: String? = nil,
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        attributes: [DOMAttribute],
        childCount: Int,
        layoutFlags: [String],
        isRendered: Bool,
        children: [DOMGraphNodeDescriptor] = [],
        contentDocument: DOMGraphNodeDescriptor? = nil,
        shadowRoots: [DOMGraphNodeDescriptor] = [],
        templateContent: DOMGraphNodeDescriptor? = nil,
        beforePseudoElement: DOMGraphNodeDescriptor? = nil,
        afterPseudoElement: DOMGraphNodeDescriptor? = nil
    ) {
        let regularChildCount = contentDocument == nil ? childCount : children.count
        self.init(
            targetIdentifier: runtimeDOMTestDefaultTargetIdentifier,
            nodeID: Int(nodeID),
            frameID: frameID,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            regularChildCount: regularChildCount,
            regularChildrenAreLoaded: !children.isEmpty || regularChildCount == 0,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            regularChildren: (!children.isEmpty || regularChildCount == 0) ? children : nil,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
        )
    }

    var childCount: Int {
        contentDocument == nil ? regularChildCount : 1
    }
}

private extension DOMGraphMutationEvent {
    static func childNodeInserted(
        parentNodeID: UInt64,
        previousNodeID: UInt64?,
        node: DOMGraphNodeDescriptor
    ) -> DOMGraphMutationEvent {
        .childNodeInserted(
            parentKey: runtimeDOMTestKey(parentNodeID),
            previousSibling: previousNodeID.map {
                $0 == 0 ? .firstChild : .node(runtimeDOMTestKey($0))
            } ?? .missing,
            node: node
        )
    }

    static func childNodeRemoved(
        parentNodeID: UInt64,
        nodeNodeID: UInt64
    ) -> DOMGraphMutationEvent {
        .childNodeRemoved(
            parentKey: runtimeDOMTestKey(parentNodeID),
            nodeKey: runtimeDOMTestKey(nodeNodeID)
        )
    }

    static func setChildNodes(
        parentNodeID: UInt64,
        nodes: [DOMGraphNodeDescriptor]
    ) -> DOMGraphMutationEvent {
        .setChildNodes(
            parentKey: runtimeDOMTestKey(parentNodeID),
            nodes: nodes
        )
    }

    static func shadowRootPushed(
        hostNodeID: UInt64,
        root: DOMGraphNodeDescriptor
    ) -> DOMGraphMutationEvent {
        .shadowRootPushed(
            hostKey: runtimeDOMTestKey(hostNodeID),
            root: root
        )
    }

    static func shadowRootPopped(
        hostNodeID: UInt64,
        rootNodeID: UInt64
    ) -> DOMGraphMutationEvent {
        .shadowRootPopped(
            hostKey: runtimeDOMTestKey(hostNodeID),
            rootKey: runtimeDOMTestKey(rootNodeID)
        )
    }

    static func pseudoElementAdded(
        parentNodeID: UInt64,
        node: DOMGraphNodeDescriptor
    ) -> DOMGraphMutationEvent {
        .pseudoElementAdded(
            parentKey: runtimeDOMTestKey(parentNodeID),
            node: node
        )
    }

    static func pseudoElementRemoved(
        parentNodeID: UInt64,
        nodeNodeID: UInt64
    ) -> DOMGraphMutationEvent {
        .pseudoElementRemoved(
            parentKey: runtimeDOMTestKey(parentNodeID),
            nodeKey: runtimeDOMTestKey(nodeNodeID)
        )
    }

}

private extension DOMSelectionSnapshotPayload {
    init(
        nodeID: Int?,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String?,
        styleRevision: Int
    ) {
        self.init(
            key: nodeID.map { runtimeDOMTestKey(UInt64($0)) },
            attributes: attributes,
            path: path,
            selectorPath: selectorPath,
            styleRevision: styleRevision
        )
    }
}

private extension DOMSelectorPathPayload {
    init(
        nodeID: Int?,
        attributes _: [DOMAttribute] = [],
        path _: [String] = [],
        selectorPath: String,
        styleRevision _: Int = 0
    ) {
        self.init(key: nodeID.map { runtimeDOMTestKey(UInt64($0)) }, selectorPath: selectorPath)
    }
}

private extension DOMDocumentModel {
    func node(nodeID: UInt64) -> DOMNodeModel? {
        runtimeDOMTestFirstNode(
            with: Int(nodeID),
            in: topLevelRoots() + detachedRootsForDiagnostics()
        )
    }

    func consumeRejectedStructuralMutationParentNodeIDs() -> Set<UInt64> {
        Set(consumeRejectedStructuralMutationParentKeys().map { UInt64($0.nodeID) })
    }
}

private extension DOMNodeModel {
    var effectiveChildren: [DOMNodeModel] {
        children
    }

    var childCount: Int {
        contentDocument == nil ? regularChildCount : 1
    }

}

private extension WIDOMInspector {
    var testPendingInspectScopedResolutionRootNodeIDs: [UInt64] {
        guard testHasInspectNodeResolution else {
            return []
        }
        return runtimeTestPendingScopedRootNodeIDsByInspector[ObjectIdentifier(self)] ?? []
    }

    func testSeedInspectNodeResolution(
        nodeID: Int,
        contextID: DOMContextID,
        outstandingNodeIDs: [UInt64],
        scopedRootNodeIDs: [UInt64]? = nil,
        activeStrategy: String? = nil,
        activeRequestGeneration: UInt64 = 0
    ) {
        runtimeTestPendingScopedRootNodeIDsByInspector[ObjectIdentifier(self)] = scopedRootNodeIDs ?? outstandingNodeIDs
        testSetInspectNodeResolution(
            nodeID: nodeID,
            contextID: contextID,
            outstandingNodeIDs: outstandingNodeIDs,
            scopedRootNodeIDs: scopedRootNodeIDs,
            activeStrategy: activeStrategy,
            activeRequestGeneration: activeRequestGeneration
        )
    }

    func testStartInspectNodeResolution(
        nodeID: Int,
        contextID: DOMContextID,
        targetIdentifier _: String
    ) async -> String {
        testSetInspectNodeResolution(
            nodeID: nodeID,
            contextID: contextID,
            outstandingNodeIDs: [],
            scopedRootNodeIDs: [],
            activeStrategy: nil,
            activeRequestGeneration: 0
        )
        return testHasInspectNodeResolution ? "waitingForMutation" : "resolved"
    }

    func testApplyMutationBundleAndResolveInspectNodeIfPossible(
        _ bundle: DOMGraphMutationBundle,
        contextID: DOMContextID
    ) async {
        await testApplyMutationBundleAndResolveInspectNodeResolution(bundle, contextID: contextID)
        if !testHasInspectNodeResolution {
            runtimeTestPendingScopedRootNodeIDsByInspector[ObjectIdentifier(self)] = nil
        }
    }
}

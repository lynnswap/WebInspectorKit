import Foundation
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
    func payloadNormalizerEmbedsContentDocumentAsCanonicalChild() throws {
        let normalizer = DOMPayloadNormalizer()
        let snapshot = try #require(normalizer.normalizeSnapshot(makeIFrameDocumentResult(url: "https://example.com/a")["root"] as Any))
        let htmlNode = try #require(snapshot.root.children.first)
        let bodyNode = try #require(htmlNode.children.first(where: { $0.localName == "body" }))
        let mainNode = try #require(bodyNode.children.first(where: { $0.localName == "main" }))
        let iframeNode = try #require(mainNode.children.first(where: { $0.localName == "iframe" }))
        let nestedDocument = try #require(iframeNode.children.first)

        #expect(iframeNode.frameID == "frame-child")
        #expect(iframeNode.childCount == 1)
        #expect(nestedDocument.nodeType == 9)
        #expect(nestedDocument.frameID == "frame-child")
        #expect(nestedDocument.children.first?.children.first?.localName == "button")
    }

    @Test
    func payloadNormalizerPreservesProtocolNodeIDsForDetachedRoots() throws {
        let normalizer = DOMPayloadNormalizer()
        let delta = try #require(
            normalizer.normalizeBundlePayload([
                "version": 2,
                "kind": "mutation",
                "events": [[
                    "method": "DOM.setChildNodes",
                    "params": [
                        "nodes": [[
                            "nodeId": 900,
                            "backendNodeId": 900,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 1093,
                                "backendNodeId": 1093,
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
                ]],
            ])
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
        #expect(nodes.first?.localID == 900)
        #expect(nodes.first?.backendNodeID == 900)
        #expect(nodes.first?.children.first?.localID == 1093)
        #expect(nodes.first?.children.first?.backendNodeID == 1093)
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
    func attachedPageWebViewDeallocationClearsAttachmentState() async {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
                                "backendNodeId": 6,
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
                            "backendNodeId": 16,
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let initiallySelected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6 && inspector.isSelectingElement == false
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
            inspector.document.selectedNode?.localID == 16
                && inspector.document.selectedNode?.nodeName == "SECTION"
                && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(inspector.document.selectedNode?.localID != 6)
        #expect(inspectModeEnabledValues == [true, false, true, false])
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
                                "backendNodeId": 16,
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
                            "backendNodeId": 6,
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 6])

        let initiallySelected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6 && inspector.isSelectingElement == false
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
            inspector.document.selectedNode?.localID == 16
                && inspector.document.selectedNode?.nodeName == "SECTION"
                && inspector.isSelectingElement == false
        }
        #expect(reselectionReady)
        #expect(inspectModeEnabledValues == [true, false, true, false])
    }

    @Test
    func freshContextDoesNotMarkFrontendCurrentBeforeInitialHydration() async throws {
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let initiallyReady = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(initiallyReady)

        let firstContextID = try #require(inspector.testCurrentContextID)
        inspector.resetFrontendHydrationDiagnosticsForTesting()
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
        let frontendReady = await waitForCondition {
            await inspector.testFrontendIsReady()
        }
        #expect(frontendReady)
        inspector.testHandleReadyMessage(contextID: currentContextID)

        let hydrationCompleted = await waitForCondition {
            return inspector.frontendHydrationDiagnosticsForTesting.contains {
                if case let .hydrated(_, eventContextID, _, _) = $0 {
                    return eventContextID == currentContextID
                }
                return false
            }
        }

        #expect(hydrationCompleted)
    }

    @Test
    func provisionalNavigationHydratesFrontendForNewContext() async throws {
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
        inspector.resetFrontendHydrationDiagnosticsForTesting()

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
        let frontendReady = await waitForCondition {
            await inspector.testFrontendIsReady()
        }
        #expect(frontendReady)
        inspector.testHandleReadyMessage(contextID: currentContextID)

        let frontendHydratedForNewContext = await waitForCondition {
            guard inspector.testCurrentDocumentURL == "https://example.com/b" else {
                return false
            }
            return inspector.frontendHydrationDiagnosticsForTesting.contains {
                switch $0 {
                case let .hydrated(reason, eventContextID, _, _),
                     let .skippedDuplicateReady(reason, eventContextID, _, _):
                    return eventContextID == currentContextID
                        && (
                            reason == "transport.refreshCurrentDocument"
                                || reason == "ready.currentContext"
                                || reason == "handleDOMEventEnvelope.deferredMutation"
                        )
                }
            }
        }

        #expect(frontendHydratedForNewContext)
    }

    @Test
    func readyFrontendReopenHydratesCurrentDocumentWithoutTransportReload() async throws {
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        let initialGetDocumentCallCount = getDocumentCallCount
        inspector.resetFrontendHydrationDiagnosticsForTesting()

        _ = inspector.makeInspectorWebView()
        let frontendReady = await waitForCondition {
            await inspector.testFrontendIsReady()
        }
        #expect(frontendReady)
        inspector.testHandleReadyMessage(contextID: contextID)
        let frontendHydratedWithoutReload = await waitForCondition {
            inspector.frontendHydrationDiagnosticsForTesting.contains {
                switch $0 {
                case let .hydrated(reason, eventContextID, _, _),
                     let .skippedDuplicateReady(reason, eventContextID, _, _):
                    return reason == "ready.currentContext" && eventContextID == contextID
                }
            }
        }

        #expect(inspector.testCurrentContextID == contextID)
        #expect(inspector.testCurrentDocumentURL == "https://example.com/a")
        #expect(frontendHydratedWithoutReload)
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
        defer {
            WIDOMUIKitSceneActivationEnvironment.requester = previousRequester
            WIDOMUIKitSceneActivationEnvironment.sceneProvider = previousSceneProvider
            WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = previousRequestingSceneProvider
            WIDOMUIKitSceneActivationEnvironment.activationTimeout = previousActivationTimeout
        }

        WIDOMUIKitSceneActivationEnvironment.requester = requester
        WIDOMUIKitSceneActivationEnvironment.sceneProvider = { _ in targetScene }
        WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider = { _ in nil }
        WIDOMUIKitSceneActivationEnvironment.activationTimeout = .milliseconds(200)

        requester.onRequest = { target in
            await requestGate.open()
            await activationGate.wait()
            targetScene.activationState = .foregroundActive
            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: target
            )
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
        }

        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in false }

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
        _ = inspector.makeInspectorWebView()
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

        await inspector.cancelSelectionMode()
        #expect(inspector.isSelectingElement == false)
        #expect(inspectModeEnabledValues == [true, false])
        #expect(nodeSearchEnabledValues.contains(true) == false)
    }

    @Test
    func selectionModeRearmsAfterFreshContextWithoutNativeEnable() async throws {
        var nodeSearchEnabledValues: [Bool] = []
        var documentVersion = 0
        let previousNodeSearchSetter = WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter
        let previousRecognizerPresenceProvider = WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider
        let previousRecognizerRemover = WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover
        let previousSelectionActiveProvider = WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider
        defer {
            WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = previousNodeSearchSetter
            WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = previousRecognizerPresenceProvider
            WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = previousRecognizerRemover
            WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = previousSelectionActiveProvider
        }

        WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter = { _, enabled in
            nodeSearchEnabledValues.append(enabled)
            return true
        }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider = { _ in false }
        WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover = { _ in true }
        WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider = { _ in false }

        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    if documentVersion == 0 {
                        return makeDocumentResult(
                            url: "https://example.com/a",
                            mainChildren: [[
                                "nodeId": 6,
                                "backendNodeId": 6,
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
                            "backendNodeId": 16,
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
            inspector.document.selectedNode?.localID == 16 && inspector.isSelectingElement == false
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
#endif

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
        _ = inspector.makeInspectorWebView()
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

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.nodeName == "A"
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
        _ = inspector.makeInspectorWebView()
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

        let selected = await waitForCondition(
            maxAttempts: 120,
            intervalNanoseconds: 20_000_000
        ) {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.nodeName == "A"
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
                                    "backendNodeId": 9000,
                                    "nodeType": 9,
                                    "nodeName": "#document",
                                    "localName": "",
                                    "nodeValue": "",
                                    "documentURL": "https://ads.example.com/frame",
                                    "childNodeCount": 1,
                                    "children": [[
                                        "nodeId": 1093,
                                        "backendNodeId": 1093,
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
                    "objectId": "node-object-detached",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode == nil
                && inspector.testHasPendingInspectSelection == false
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
                                "backendNodeId": 900,
                                "nodeType": 9,
                                "nodeName": "#document",
                                "localName": "",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 1093,
                                    "backendNodeId": 1093,
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
                                "backendNodeId": 910,
                                "nodeType": 9,
                                "nodeName": "#document",
                                "localName": "",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 2093,
                                    "backendNodeId": 2093,
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
                    "objectId": "node-object-detached-later-root",
                ],
                "hints": [:],
            ]
        )

        let failed = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode == nil
                && inspector.testHasPendingInspectSelection == false
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
        _ = inspector.makeInspectorWebView()
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
                    "backendNodeId": 900,
                    "nodeType": 9,
                    "nodeName": "#document",
                    "localName": "",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 1093,
                        "backendNodeId": 1093,
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
        _ = inspector.makeInspectorWebView()
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
            inspector.document.selectedNode?.localID == 26 && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(requestNodeTargets == ["frame-target-A"])
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let iframeNode = try #require(inspector.document.node(localID: 20))
        let nestedDocument = try #require(iframeNode.children.first)
        #expect(nestedDocument.nodeType == 9)
        #expect(nestedDocument.frameID == "frame-child")
        #expect(nestedDocument.parent?.localID == iframeNode.localID)

        try await inspector.beginSelectionMode()
        backend.emitPageEvent(method: "DOM.inspect", params: ["nodeId": 26])

        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 26
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "frame-target" }) == true
                && inspector.isSelectingElement == false
        }
        #expect(selected)
    }

    @Test
    func inspectorInspectMergesFrameTargetDocumentIntoKnownNestedDocument() async throws {
        var requestNodeTargets: [String] = []
        let backend = FakeDOMTransportBackend()
        backend.pageResultProvider = { method, payload, targetIdentifier in
            switch method {
            case WITransportMethod.DOM.getDocument:
                if targetIdentifier == "frame-target-A" {
                    return [
                        "root": [
                            "nodeId": 240,
                            "backendNodeId": 240,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "documentURL": "https://example.com/frame",
                            "frameId": "frame-child",
                            "childNodeCount": 1,
                            "children": [[
                                "nodeId": 241,
                                "backendNodeId": 241,
                                "nodeType": 1,
                                "nodeName": "HTML",
                                "localName": "html",
                                "nodeValue": "",
                                "childNodeCount": 1,
                                "children": [[
                                    "nodeId": 260,
                                    "backendNodeId": 260,
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
        _ = inspector.makeInspectorWebView()
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
            inspector.document.selectedNode?.backendNodeID == 260
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "frame-target" }) == true
                && inspector.isSelectingElement == false
        }
        #expect(selected)
        #expect(inspector.document.selectedNode?.localID != 20)
        #expect(requestNodeTargets == ["frame-target-A"])
        let nestedDocument = try #require(inspector.document.node(localID: 24))
        #expect(nestedDocument.children.first?.localID == 241)
        #expect(inspector.document.node(localID: 260)?.backendNodeID == 260)
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
        _ = inspector.makeInspectorWebView()
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
            inspector.document.selectedNode?.localID == 6
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
    func inspectorInspectDoesNotRequestChildNodesWhenRequestNodeReturnsUnresolvedNode() async throws {
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
        _ = inspector.makeInspectorWebView()
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
                        localID: 20,
                        backendNodeID: 20,
                        frameID: "frame-a",
                        idAttribute: "frame-owner-a",
                        childCount: 1,
                        children: [
                            makeFrameDocumentDescriptor(
                                localID: 24,
                                backendNodeID: 24,
                                frameID: "frame-a",
                                childCount: 2
                            )
                        ]
                    ),
                    makeFrameOwnerDescriptor(
                        localID: 30,
                        backendNodeID: 30,
                        frameID: "frame-b",
                        idAttribute: "frame-owner-b",
                        childCount: 1
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
                && inspector.testHasPendingInspectSelection == false
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
        _ = inspector.makeInspectorWebView()
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
        _ = inspector.makeInspectorWebView()
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
        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.nodeName == "A"
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
        _ = inspector.makeInspectorWebView()
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

        let selected = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.nodeName == "A"
                && inspector.document.errorMessage == nil
        }
        #expect(selected)
        #expect(requestedObjectIDs.isEmpty)
    }

    @Test
    func frontendSelectionIsIgnoredWhileInspectorInspectMaterializesSelection() async throws {
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

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetPendingInspectSelection(
            nodeID: 3,
            contextID: contextID,
            outstandingLocalIDs: []
        )

        let competingSelection = DOMSelectionSnapshotPayload(
            localID: 3,
            backendNodeID: 3,
            backendNodeIDIsStable: true,
            preview: "<body>",
            attributes: [],
            path: ["html", "body"],
            selectorPath: "body",
            styleRevision: 0
        )
        inspector.testHandleInspectorSelection(competingSelection)

        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.testHasPendingInspectSelection)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func frontendSelectionRefinesPendingInspectSelectionWhenDifferentNodeArrives() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        bodyChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetPendingInspectSelection(
            nodeID: 3,
            contextID: contextID,
            outstandingLocalIDs: []
        )

        inspector.testHandleInspectorSelection(
            DOMSelectionSnapshotPayload(
                localID: 6,
                backendNodeID: 6,
                backendNodeIDIsStable: true,
                preview: "<a>",
                attributes: [DOMAttribute(nodeId: 6, name: "id", value: "refined")],
                path: ["html", "body", "a"],
                selectorPath: "#refined",
                styleRevision: 0
            )
        )

        let refined = await waitForCondition {
            inspector.document.selectedNode?.localID == 6
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "refined" }) == true
                && inspector.testHasPendingInspectSelection == false
                && inspector.document.errorMessage == nil
        }
        #expect(refined)
    }

    @Test
    func frontendSelectionDoesNotOverrideCurrentSelectionWhilePendingInspectSelectionExists() async throws {
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, _, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(
                        url: "https://example.com/a",
                        bodyChildren: [[
                            "nodeId": 6,
                            "backendNodeId": 6,
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
        _ = inspector.makeInspectorWebView()
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
                localID: existingNode.localID,
                backendNodeID: existingNode.backendNodeID,
                backendNodeIDIsStable: existingNode.backendNodeIDIsStable,
                preview: "<\(existingNode.localName)>",
                attributes: existingNode.attributes,
                path: [existingNode.localName],
                selectorPath: existingNode.localName,
                styleRevision: existingNode.styleRevision
            )
        )
        inspector.testSetPendingInspectSelection(
            nodeID: 3,
            contextID: contextID,
            outstandingLocalIDs: []
        )

        inspector.testHandleInspectorSelection(
            DOMSelectionSnapshotPayload(
                localID: 6,
                backendNodeID: 6,
                backendNodeIDIsStable: true,
                preview: "<a>",
                attributes: [DOMAttribute(nodeId: 6, name: "id", value: "refined")],
                path: ["html", "body", "a"],
                selectorPath: "#refined",
                styleRevision: 0
            )
        )

        #expect(inspector.document.selectedNode?.localID == existingNode.localID)
        #expect(inspector.testHasPendingInspectSelection)
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
                        message: "child materialization failed"
                    )
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

        let existingNode = try #require(inspector.document.node(localID: 4))
        inspector.document.applySelectionSnapshot(
            .init(
                localID: existingNode.localID,
                backendNodeID: existingNode.backendNodeID,
                backendNodeIDIsStable: existingNode.backendNodeIDIsStable,
                preview: "<main>",
                attributes: existingNode.attributes,
                path: ["html", "body", "main"],
                selectorPath: "#root",
                styleRevision: existingNode.styleRevision
            )
        )
        #expect(inspector.document.selectedNode?.localID == 4)

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
            inspector.document.selectedNode?.localID == 4
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.testHasPendingInspectSelection == false
                && inspector.isSelectingElement == false
        }
        #expect(failed)
    }

    @Test
    func pendingInspectSelectionSurvivesEmptyFrameOwnerSetChildNodesAndResolvesInsideContentDocument() async throws {
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

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        localID: 800,
                        backendNodeID: 800,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        children: [
                            makeFrameDocumentDescriptor(
                                localID: 801,
                                backendNodeID: 801,
                                frameID: "frame-owner",
                                childCount: 0,
                                children: []
                            )
                        ]
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetPendingInspectSelection(
            nodeID: 928,
            contextID: contextID,
            outstandingLocalIDs: [801],
            scopedRootLocalIDs: [801]
        )

        let htmlNode = DOMGraphNodeDescriptor(
            localID: 951,
            backendNodeID: 951,
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
                    localID: 955,
                    backendNodeID: 955,
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
                            localID: 928,
                            backendNodeID: 928,
                            backendNodeIDIsStable: true,
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
                    .setChildNodes(parentLocalID: 800, nodes: []),
                    .setChildNodes(parentLocalID: 801, nodes: [htmlNode])
                ]
            ),
            contextID: contextID
        )

        let selectedNode = try #require(inspector.document.selectedNode)
        #expect(selectedNode.localID == 928)
        #expect(selectedNode.backendNodeID == 928)
        #expect(selectedNode.parent?.localID == 955)
        #expect(inspector.testHasPendingInspectSelection == false)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func pendingInspectSelectionSurvivesEmptyFrameOwnerSetChildNodesWhenNodeTypesAreMissing() async throws {
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

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    DOMGraphNodeDescriptor(
                        localID: 800,
                        backendNodeID: 800,
                        backendNodeIDIsStable: true,
                        frameID: "frame-owner",
                        nodeType: 0,
                        nodeName: "IFRAME",
                        localName: "iframe",
                        nodeValue: "",
                        attributes: [.init(name: "id", value: "frame-owner")],
                        childCount: 1,
                        layoutFlags: [],
                        isRendered: true,
                        children: [
                            DOMGraphNodeDescriptor(
                                localID: 801,
                                backendNodeID: 801,
                                backendNodeIDIsStable: true,
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
                        ]
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetPendingInspectSelection(
            nodeID: 928,
            contextID: contextID,
            outstandingLocalIDs: [801],
            scopedRootLocalIDs: [801]
        )

        let htmlNode = DOMGraphNodeDescriptor(
            localID: 951,
            backendNodeID: 951,
            backendNodeIDIsStable: true,
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
                    localID: 955,
                    backendNodeID: 955,
                    backendNodeIDIsStable: true,
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
                            localID: 928,
                            backendNodeID: 928,
                            backendNodeIDIsStable: true,
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
                    .setChildNodes(parentLocalID: 800, nodes: []),
                    .setChildNodes(parentLocalID: 801, nodes: [htmlNode])
                ]
            ),
            contextID: contextID
        )

        let selectedNode = try #require(inspector.document.selectedNode)
        #expect(selectedNode.localID == 928)
        #expect(selectedNode.parent?.localID == 955)
        #expect(inspector.testHasPendingInspectSelection == false)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func pendingInspectMaterializationDoesNotSelectIframeOwnerWhenScopedResolutionIsUnresolved() async throws {
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

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        localID: 774,
                        backendNodeID: 774,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        children: [
                            makeFrameDocumentDescriptor(
                                localID: 775,
                                backendNodeID: 775,
                                frameID: "frame-owner",
                                childCount: 1,
                                children: []
                            )
                        ]
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetPendingInspectSelection(
            nodeID: 999,
            contextID: contextID,
            outstandingLocalIDs: [775],
            scopedRootLocalIDs: [775]
        )

        let htmlNode = DOMGraphNodeDescriptor(
            localID: 956,
            backendNodeID: 956,
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
                    localID: 958,
                    backendNodeID: 958,
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
                            localID: 959,
                            backendNodeID: 959,
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

        await inspector.testApplyMutationBundleAndFinishPendingInspectMaterialization(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(parentLocalID: 775, nodes: [htmlNode])
                ]
            ),
            contextID: contextID
        )

        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.selectedNode?.localID != 774)
        #expect(inspector.testHasPendingInspectSelection)
        #expect(inspector.testPendingInspectScopedMaterializationRootLocalIDs == [775])
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func pendingInspectSelectionResolvesExactNodeFromUnknownParentSetChildNodesEvent() async throws {
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

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeFrameOwnerDescriptor(
                        localID: 774,
                        backendNodeID: 774,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        children: [
                            makeFrameDocumentDescriptor(
                                localID: 775,
                                backendNodeID: 775,
                                frameID: "frame-owner",
                                childCount: 1,
                                children: []
                            )
                        ]
                    )
                ]
            ),
            isFreshDocument: true
        )

        let contextID = try #require(inspector.testCurrentContextID)
        inspector.testSetPendingInspectSelection(
            nodeID: 7574,
            contextID: contextID,
            outstandingLocalIDs: [],
            scopedRootLocalIDs: [775]
        )

        await inspector.testHandleMutationBundleThroughTransportPath(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(
                        parentLocalID: 7572,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                localID: 7573,
                                backendNodeID: 7573,
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
                                        localID: 7575,
                                        backendNodeID: 7575,
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
                                                localID: 7574,
                                                backendNodeID: 7574,
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
        #expect(inspector.document.node(localID: 7574) == nil)
        #expect(inspector.testHasPendingInspectSelection)
        #expect(inspector.document.errorMessage == nil)
        #expect(inspector.document.topLevelRoots().map(\.localID) == [1])
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
        _ = inspector.makeInspectorWebView()
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
                        parentLocalID: 646,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                localID: 647,
                                backendNodeID: 647,
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
                        parentLocalID: 647,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                localID: 664,
                                backendNodeID: 664,
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

        #expect(inspector.document.node(localID: 664) == nil)

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
                && inspector.testHasPendingInspectSelection == false
                && inspector.document.node(localID: 664) == nil
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
        _ = inspector.makeInspectorWebView()
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
                        localID: 774,
                        backendNodeID: 774,
                        frameID: "frame-owner",
                        idAttribute: "frame-owner",
                        childCount: 1,
                        children: [
                            makeFrameDocumentDescriptor(
                                localID: 775,
                                backendNodeID: 775,
                                frameID: "frame-owner",
                                childCount: 1,
                                children: []
                            )
                        ]
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
                        parentLocalID: 646,
                        nodes: [
                            DOMGraphNodeDescriptor(
                                localID: 647,
                                backendNodeID: 647,
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
                                        localID: 648,
                                        backendNodeID: 648,
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
                                                localID: 664,
                                                backendNodeID: 664,
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
                && inspector.testHasPendingInspectSelection == false
                && inspector.document.errorMessage == "Failed to resolve selected element."
                && inspector.document.topLevelRoots().map(\.localID) == [1]
        }
        #expect(failed)

        #expect(inspector.document.node(localID: 775)?.localID == 775)
        #expect(inspector.document.node(localID: 664) == nil)
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
        _ = inspector.makeInspectorWebView()
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
                                localID: 647,
                                backendNodeID: 647,
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
                                        localID: 664,
                                        backendNodeID: 664,
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

        let detachedNode = try #require(inspector.document.node(localID: 664))
        inspector.document.applySelectionSnapshot(
            .init(
                localID: detachedNode.localID,
                backendNodeID: detachedNode.backendNodeID,
                backendNodeIDIsStable: detachedNode.backendNodeIDIsStable,
                preview: "",
                attributes: detachedNode.attributes,
                path: [],
                selectorPath: nil,
                styleRevision: detachedNode.styleRevision
            )
        )

        #expect(inspector.testFrontendSnapshotRootLocalID == 1)
        #expect(inspector.testFrontendSnapshotRootChildLocalIDs.contains(647) == false)
        #expect(inspector.document.topLevelRoots().map(\.localID) == [1])
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
    func selectNodeForTestingMaterializesCurrentDocumentSubtreeForSelector() async throws {
        var requestedNodeIDs: [Int] = []
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
        _ = inspector.makeInspectorWebView()
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        let ready = await waitForCondition {
            inspector.testIsReady && inspector.document.rootNode != nil
        }
        #expect(ready)

        try await inspector.selectNodeForTesting(cssSelector: "#frame-target")

        #expect(inspector.document.selectedNode?.localID == 26)
        #expect(inspector.document.selectedNode?.selectorPath == "#frame-target")
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    func copySelectedSelectorPathGeneratesPathLocally() async throws {
        let inspector = WIDOMInspector()
        let normalizer = DOMPayloadNormalizer()
        let snapshot = try #require(normalizer.normalizeSnapshot(makeDocumentResult(url: "https://example.com/a")))
        inspector.document.replaceDocument(
            with: .init(root: snapshot.root, selectedLocalID: 5),
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
        let snapshot = try #require(normalizer.normalizeSnapshot(makeIFrameDocumentResult(url: "https://example.com/a")))
        inspector.document.replaceDocument(
            with: .init(root: snapshot.root, selectedLocalID: 26),
            isFreshDocument: true
        )

        let selectorPath = try await inspector.copySelectedSelectorPath()
        let xpath = try await inspector.copySelectedXPath()

        #expect(selectorPath == "#frame-owner > html > #frame-target")
        #expect(xpath == "/html/body/main/iframe/html/button")
    }

    @Test
    func copyNodeByBackendIDPrefersBackendNodeOverLocalIDCollision() async throws {
        let backend = FakeDOMTransportBackend()
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        inspector.document.replaceDocument(
            with: makeMainDocumentSnapshot(
                mainChildren: [
                    makeElementDescriptor(
                        localID: 42,
                        backendNodeID: 900,
                        localName: "div",
                        idAttribute: "local-collision"
                    ),
                    makeElementDescriptor(
                        localID: 7,
                        backendNodeID: 42,
                        localName: "section",
                        idAttribute: "backend-target"
                    ),
                ]
            ),
            isFreshDocument: true
        )

        let selectorPath = try await inspector.copyNode(nodeId: 42, kind: .selectorPath)

        #expect(selectorPath == "#backend-target")
    }

    @Test
    func copyNodeByBackendIDFallsBackToDirectBackendHTMLWhenMirrorNodeIsMissing() async throws {
        var requestedNodeID: Int?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com")
                case WITransportMethod.DOM.getOuterHTML:
                    requestedNodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"])
                    return ["outerHTML": "<div id=\"backend-only\"></div>"]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        let html = try await inspector.copyNode(nodeId: 777, kind: .html)

        #expect(requestedNodeID == 777)
        #expect(html == "<div id=\"backend-only\"></div>")
    }

    @Test
    func deleteNodeByBackendIDPrefersBackendNodeOverLocalIDCollision() async throws {
        var removedNodeID: Int?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com")
                case WITransportMethod.DOM.removeNode:
                    removedNodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"])
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
                        localID: 42,
                        backendNodeID: 900,
                        localName: "div",
                        idAttribute: "local-collision"
                    ),
                    makeElementDescriptor(
                        localID: 7,
                        backendNodeID: 42,
                        localName: "section",
                        idAttribute: "backend-target"
                    ),
                ]
            ),
            isFreshDocument: true
        )

        try await inspector.deleteNode(nodeId: 42, undoManager: nil)

        #expect(removedNodeID == 42)
        #expect(inspector.document.node(localID: 42) != nil)
        #expect(inspector.document.node(backendNodeID: 42) == nil)
    }

    @Test
    func deleteNodeByBackendIDFallsBackToDirectBackendDeleteWhenMirrorNodeIsMissing() async throws {
        var removedNodeID: Int?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com")
                case WITransportMethod.DOM.removeNode:
                    removedNodeID = runtimeTestIntValue((payload["params"] as? [String: Any])?["nodeId"])
                    return [:]
                default:
                    return [:]
                }
            }
        )
        let inspector = makeInspector(using: backend)
        let webView = makeTestWebView()
        await inspector.attach(to: webView)

        try await inspector.deleteNode(nodeId: 777, undoManager: nil)

        #expect(removedNodeID == 777)
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
    func selectNodeForTestingPreviewWaitsForRequestedChildNodesBeforeFallbackResolution() async throws {
        var didRequestChildNodes = false
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return [
                        "root": [
                            "nodeId": 1,
                            "backendNodeId": 1,
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
        _ = inspector.makeInspectorWebView()
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
                    "backendNodeId": 2,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "attributes": [],
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 3,
                        "backendNodeId": 3,
                        "nodeType": 1,
                        "nodeName": "BODY",
                        "localName": "body",
                        "nodeValue": "",
                        "attributes": [],
                        "childNodeCount": 1,
                        "children": [[
                            "nodeId": 6,
                            "backendNodeId": 6,
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

        #expect(inspector.document.selectedNode?.localID == 6)
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
    func frontendHoverHighlightPreservesRevealFalse() async throws {
        var lastHighlightReveal: Bool?
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                switch method {
                case WITransportMethod.DOM.getDocument:
                    return makeDocumentResult(url: "https://example.com/a")
                case WITransportMethod.DOM.highlightNode:
                    let params = runtimeTestDictionaryValue(payload["params"])
                    lastHighlightReveal = params?["reveal"] as? Bool
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
    }

    @Test
    func successfulInspectReappliesPersistentHighlightAfterInspectModeTeardown() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled,
                   let params = runtimeTestDictionaryValue(payload["params"]) {
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
            return inspector.document.selectedNode?.localID == 6
                && inspector.isSelectingElement == false
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
                   let params = runtimeTestDictionaryValue(payload["params"]) {
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
            return inspector.document.selectedNode?.localID == 6
                && inspector.document.errorMessage == nil
                && inspector.isSelectingElement == false
                && highlightIndex >= 0
        }
        #expect(preserved)
    }

    @Test
    func inspectorInspectResolvesNodeBeforeInspectModeTeardown() async throws {
        var pageCalls: [(method: String, inspectModeEnabled: Bool?)] = []
        let backend = FakeDOMTransportBackend(
            pageResultProvider: { method, payload, _ in
                let inspectModeEnabled: Bool?
                if method == WITransportMethod.DOM.setInspectModeEnabled,
                   let params = runtimeTestDictionaryValue(payload["params"]) {
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
                && inspector.isSelectingElement == false
                && inspector.document.errorMessage == nil
        }
        #expect(selected)

        let requestNodeIndex = pageCalls.lastIndex(where: { $0.method == WITransportMethod.DOM.requestNode })
        let disableInspectIndex = pageCalls.lastIndex(where: {
            $0.method == WITransportMethod.DOM.setInspectModeEnabled && $0.inspectModeEnabled == false
        })
        #expect(requestNodeIndex != nil)
        #expect(disableInspectIndex != nil)
        if let requestNodeIndex, let disableInspectIndex {
            #expect(requestNodeIndex < disableInspectIndex)
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
private func makeInspector(
    configuration: DOMConfiguration = .init(),
    using backend: FakeDOMTransportBackend,
    derivedPageTargetIdentifier: String? = nil
) -> WIDOMInspector {
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
        configuration: configuration,
        sharedTransport: sharedTransport
    )
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

private func makeIFrameDocumentResult(url: String) -> [String: Any] {
    makeDocumentResult(
        url: url,
        mainChildren: [[
            "nodeId": 20,
            "backendNodeId": 20,
            "nodeType": 1,
            "nodeName": "IFRAME",
            "localName": "iframe",
            "nodeValue": "",
            "attributes": ["id", "frame-owner"],
            "frameId": "frame-child",
            "childNodeCount": 1,
            "contentDocument": [
                "nodeId": 24,
                "backendNodeId": 24,
                "nodeType": 9,
                "nodeName": "#document",
                "localName": "",
                "nodeValue": "",
                "documentURL": "https://example.com/frame",
                "frameId": "frame-child",
                "childNodeCount": 1,
                "children": [[
                    "nodeId": 25,
                    "backendNodeId": 25,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "childNodeCount": 1,
                    "children": [[
                        "nodeId": 26,
                        "backendNodeId": 26,
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
            "backendNodeId": 20,
            "nodeType": 1,
            "nodeName": "IFRAME",
            "localName": "iframe",
            "nodeValue": "",
            "attributes": ["id", "frame-owner"],
            "frameId": "frame-child",
            "childNodeCount": 1,
            "contentDocument": [
                "nodeId": 24,
                "backendNodeId": 24,
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
                DOMGraphNodeDescriptor(
                    localID: 2,
                    backendNodeID: 2,
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
                            localID: 3,
                            backendNodeID: 3,
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
                                    localID: 4,
                                    backendNodeID: 4,
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
    localID: UInt64,
    backendNodeID: Int,
    frameID: String,
    idAttribute: String,
    titleAttribute: String? = nil,
    childCount: Int,
    children: [DOMGraphNodeDescriptor] = []
) -> DOMGraphNodeDescriptor {
    var attributes = [DOMAttribute(name: "id", value: idAttribute)]
    if let titleAttribute {
        attributes.append(.init(name: "title", value: titleAttribute))
    }
    return DOMGraphNodeDescriptor(
        localID: localID,
        backendNodeID: backendNodeID,
        frameID: frameID,
        nodeType: 1,
        nodeName: "iframe",
        localName: "iframe",
        nodeValue: "",
        attributes: attributes,
        childCount: childCount,
        layoutFlags: [],
        isRendered: true,
        children: children
    )
}

private func makeElementDescriptor(
    localID: UInt64,
    backendNodeID: Int,
    localName: String,
    idAttribute: String? = nil,
    children: [DOMGraphNodeDescriptor] = []
) -> DOMGraphNodeDescriptor {
    var attributes: [DOMAttribute] = []
    if let idAttribute {
        attributes.append(.init(name: "id", value: idAttribute))
    }
    return DOMGraphNodeDescriptor(
        localID: localID,
        backendNodeID: backendNodeID,
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
    localID: UInt64,
    backendNodeID: Int,
    frameID: String,
    childCount: Int,
    children: [DOMGraphNodeDescriptor] = []
) -> DOMGraphNodeDescriptor {
    DOMGraphNodeDescriptor(
        localID: localID,
        backendNodeID: backendNodeID,
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

@MainActor
private final class FakeDOMTransportBackend: WITransportPlatformBackend {
    var supportSnapshot: WITransportSupportSnapshot
    var pageResultProvider: ((String, [String: Any], String) throws -> [String: Any])?
    var attachError: Error?

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
        _ = webView
        if let attachError {
            throw attachError
        }
        self.messageSink = messageSink
        if emitsInitialPageTargetCreatedOnAttach {
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
            )
            await messageSink.waitForPendingMessages()
        }
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

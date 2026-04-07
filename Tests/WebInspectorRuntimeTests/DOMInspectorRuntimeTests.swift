import Foundation
import Testing
import WebKit
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

actor BootstrapHarness {
    private var started = false
    private var resumed = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func blockUntilResumed() async {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        if resumed {
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if resumed {
                    continuation.resume()
                    return
                }
                resumeContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.resume()
            }
        }
    }

    func resume() {
        guard !resumed else {
            return
        }
        resumed = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

@MainActor
struct DOMInspectorRuntimeTests {
    @Test
    func payloadNormalizerKeepsFallbackLocalIDUniqueAcrossCallsUntilDocumentReset() {
        let normalizer = DOMPayloadNormalizer()
        let payload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "root": [
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "nodeValue": "",
                    "attributes": [],
                    "children": [],
                ],
            ],
        ]

        let firstID = rootLocalID(from: normalizer.normalizeBundlePayload(payload))
        let secondID = rootLocalID(from: normalizer.normalizeBundlePayload(payload))
        #expect(firstID != nil)
        #expect(secondID != nil)
        #expect(firstID != secondID)

        normalizer.resetForDocumentUpdate()
        let thirdID = rootLocalID(from: normalizer.normalizeBundlePayload(payload))
        #expect(thirdID == firstID)
    }

    @Test
    func payloadNormalizerResolvesSelectionByPathWhenSelectedNodeIDIsMissing() {
        let normalizer = DOMPayloadNormalizer()
        let payload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "selectedNodeId": NSNull(),
                "selectedNodePath": [1, 0],
                "root": [
                    "nodeId": 100,
                    "nodeType": 1,
                    "nodeName": "HTML",
                    "localName": "html",
                    "nodeValue": "",
                    "attributes": [],
                    "children": [
                        [
                            "nodeId": 200,
                            "nodeType": 1,
                            "nodeName": "BODY",
                            "localName": "body",
                            "nodeValue": "",
                            "attributes": [],
                            "children": [],
                        ],
                        [
                            "nodeId": 300,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 400,
                                    "nodeType": 1,
                                    "nodeName": "SPAN",
                                    "localName": "span",
                                    "nodeValue": "",
                                    "attributes": [],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]

        guard case let .snapshot(snapshot, _) = normalizer.normalizeBundlePayload(payload) else {
            Issue.record("Failed to normalize snapshot payload")
            return
        }
        #expect(snapshot.selectedLocalID == 400)
    }

    @Test
    func payloadNormalizerResetsFallbackLocalIDBeforeFreshDocumentNormalization() {
        let normalizer = DOMPayloadNormalizer()
        let snapshotPayload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "root": anonymousNodePayload(),
            ],
        ]

        let firstID = rootLocalID(from: normalizer.normalizeBundlePayload(snapshotPayload))
        _ = rootLocalID(from: normalizer.normalizeBundlePayload(snapshotPayload))

        let responseObject: [String: Any] = [
            "result": [
                "root": anonymousNodePayload(),
            ],
        ]
        guard case let .snapshot(snapshot, resetDocument)? = normalizer.normalizeBackendResponse(
            method: "DOM.getDocument",
            responseObject: responseObject,
            resetDocument: true
        ) else {
            Issue.record("Failed to normalize backend DOM.getDocument response")
            return
        }
        guard let firstID else {
            Issue.record("Failed to resolve baseline fallback localID")
            return
        }

        #expect(resetDocument == true)
        #expect(snapshot.root.localID == firstID)
        let nextID = rootLocalID(from: normalizer.normalizeBundlePayload(snapshotPayload))
        #expect(nextID == firstID + 1)
    }

    @Test
    func payloadNormalizerPreservesZeroPreviousNodeIDForPrependInsertion() {
        let normalizer = DOMPayloadNormalizer()
        let payload: [String: Any] = [
            "version": 1,
            "kind": "mutation",
            "events": [
                [
                    "method": "DOM.childNodeInserted",
                    "params": [
                        "parentNodeId": 1,
                        "previousNodeId": 0,
                        "node": [
                            "nodeId": 2,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                            "children": [],
                        ],
                    ],
                ],
            ],
        ]

        guard case let .mutations(bundle) = normalizer.normalizeBundlePayload(payload) else {
            Issue.record("Failed to normalize mutation payload")
            return
        }
        guard case let .childNodeInserted(parentLocalID, previousLocalID, node) = bundle.events.first else {
            Issue.record("Failed to decode childNodeInserted event")
            return
        }

        #expect(parentLocalID == 1)
        #expect(previousLocalID == 0)
        #expect(node.localID == 2)
    }

    @Test
    func documentUpdatedMutationDoesNotRewindFallbackCounterAfterNormalization() {
        let normalizer = DOMPayloadNormalizer()
        let snapshotPayload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "root": anonymousNodePayload(),
            ],
        ]

        let firstRootID = rootLocalID(from: normalizer.normalizeBundlePayload(snapshotPayload))
        let secondRootID = rootLocalID(from: normalizer.normalizeBundlePayload(snapshotPayload))

        let mutationPayload: [String: Any] = [
            "version": 1,
            "kind": "mutation",
            "events": [
                [
                    "method": "DOM.documentUpdated",
                    "params": [:],
                ],
                [
                    "method": "DOM.setChildNodes",
                    "params": [
                        "parentNodeId": 1,
                        "nodes": [anonymousNodePayload()],
                    ],
                ],
            ],
        ]
        _ = normalizer.normalizeBundlePayload(mutationPayload)
        let rootIDAfterDocumentUpdate = rootLocalID(from: normalizer.normalizeBundlePayload(snapshotPayload))

        guard let firstRootID else {
            Issue.record("Failed to resolve baseline root localID")
            return
        }
        #expect(secondRootID == firstRootID + 1)
        #expect(rootIDAfterDocumentUpdate == firstRootID + 1)
    }

    @Test
    func payloadNormalizerPrefersFallbackRootWhenSerializedNodeLacksStableIDs() {
        let normalizer = DOMPayloadNormalizer()
        let payload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "type": "serialized-node-envelope",
                "node": [
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "nodeValue": "",
                    "attributes": [],
                    "children": [],
                ],
                "fallback": [
                    "root": [
                        "nodeId": 777,
                        "nodeType": 1,
                        "nodeName": "DIV",
                        "localName": "div",
                        "nodeValue": "",
                        "attributes": [],
                        "children": [],
                    ],
                    "selectedNodeId": 777,
                ],
                "selectedNodeId": 777,
            ],
        ]

        guard case let .snapshot(snapshot, _) = normalizer.normalizeBundlePayload(payload) else {
            Issue.record("Failed to normalize serialized-node envelope snapshot")
            return
        }
        #expect(snapshot.root.localID == 777)
        #expect(snapshot.selectedLocalID == 777)
    }

    @Test
    func payloadNormalizerPrefersFallbackRootWhenItCarriesLocalIDsAlongsideStableIDs() {
        let normalizer = DOMPayloadNormalizer()
        let payload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "type": "serialized-node-envelope",
                "node": [
                    "nodeId": 901,
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "nodeValue": "",
                    "attributes": [],
                    "children": [],
                ],
                "fallback": [
                    "root": [
                        "nodeId": 901,
                        "localId": 77,
                        "nodeType": 1,
                        "nodeName": "DIV",
                        "localName": "div",
                        "nodeValue": "",
                        "attributes": [],
                        "children": [],
                    ],
                    "selectedNodeId": 901,
                    "selectedLocalId": 77,
                ],
                "selectedNodeId": 901,
                "selectedLocalId": 77,
            ],
        ]

        guard case let .snapshot(snapshot, _) = normalizer.normalizeBundlePayload(payload) else {
            Issue.record("Failed to normalize serialized-node envelope snapshot with local IDs")
            return
        }
        #expect(snapshot.root.backendNodeID == 901)
        #expect(snapshot.root.localID == 77)
        #expect(snapshot.selectedLocalID == 77)
    }

    @Test
    func mutationPipelineBuildsJSONSafeBufferPayloadFromSerializedNodeEnvelopeFallback() throws {
        let payloads: [[String: Any]] = [[
            "bundle": [
                "version": 1,
                "kind": "snapshot",
                "snapshot": [
                    "type": "serialized-node-envelope",
                    "node": NSObject(),
                    "fallback": [
                        "root": [
                            "nodeId": 321,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                            "children": [],
                        ],
                        "selectedNodeId": 321,
                    ],
                    "selectedNodeId": 321,
                ],
            ],
            "mode": "preserve-ui-state",
        ]]

        let jsonSafePayloads = try #require(DOMMutationPipeline.makeBufferTransportPayload(payloads))
        #expect(JSONSerialization.isValidJSONObject(jsonSafePayloads))

        let firstPayload = try #require(jsonSafePayloads.first as? [String: Any])
        let bundle = try #require(firstPayload["bundle"] as? [String: Any])
        let snapshot = try #require(bundle["snapshot"] as? [String: Any])
        #expect(snapshot["selectedNodeId"] as? Int == 321)
        let root = try #require(snapshot["root"] as? [String: Any])
        #expect(root["nodeId"] as? Int == 321)
        #expect(snapshot["type"] == nil)
    }

    @Test
    func mutationPipelineRejectsBufferPayloadWhenUnknownObjectCannotBeSanitized() {
        let payloads: [[String: Any]] = [[
            "bundle": [
                "version": 1,
                "kind": "snapshot",
                "snapshot": [
                    "type": "serialized-node-envelope",
                    "node": NSObject(),
                    "fallback": NSObject(),
                ],
            ],
            "mode": "preserve-ui-state",
        ]]

        #expect(DOMMutationPipeline.makeBufferTransportPayload(payloads) == nil)
    }

    @Test
    func mutationPipelineBufferPayloadStillNormalizesThroughFallbackSnapshot() throws {
        let payloads: [[String: Any]] = [[
            "bundle": [
                "version": 1,
                "kind": "snapshot",
                "snapshot": [
                    "type": "serialized-node-envelope",
                    "node": NSObject(),
                    "fallback": [
                        "root": [
                            "nodeId": 888,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "nodeValue": "",
                            "attributes": [],
                            "children": [],
                        ],
                        "selectedNodeId": 888,
                    ],
                    "selectedNodeId": 888,
                ],
            ],
            "mode": "preserve-ui-state",
        ]]
        let normalizer = DOMPayloadNormalizer()

        let jsonSafePayloads = try #require(DOMMutationPipeline.makeBufferTransportPayload(payloads))
        let firstPayload = try #require(jsonSafePayloads.first as? [String: Any])
        let bundle = try #require(firstPayload["bundle"] as? [String: Any])

        guard case let .snapshot(snapshot, _) = normalizer.normalizeBundlePayload(bundle) else {
            Issue.record("Failed to normalize buffer-safe fallback snapshot payload")
            return
        }
        #expect(snapshot.root.localID == 888)
        #expect(snapshot.selectedLocalID == 888)
    }

    @Test
    func payloadNormalizerParsesStringResultForChildNodeResponse() {
        let normalizer = DOMPayloadNormalizer()
        let resultJSON = """
        {
          "nodeId": 123,
          "nodeType": 1,
          "nodeName": "DIV",
          "localName": "div",
          "nodeValue": "",
          "attributes": [],
          "children": []
        }
        """
        let responseObject: [String: Any] = [
            "result": resultJSON,
        ]

        guard case let .replaceSubtree(node) = normalizer.normalizeBackendResponse(
            method: "DOM.requestChildNodes",
            responseObject: responseObject,
            resetDocument: false
        ) else {
            Issue.record("Failed to normalize string result for backend child-node response")
            return
        }

        #expect(node.localID == 123)
        #expect(node.nodeName == "DIV")
    }

    @Test
    func bundleFlushIntervalClampsToExpectedRange() async {
        let store = makeStore(autoUpdateDebounce: 0.01)
        #expect(abs(store.testBundleFlushInterval - 0.05) < 0.0001)

        await store.updateConfiguration(
            .init(snapshotDepth: 4, subtreeDepth: 3, autoUpdateDebounce: 0.4)
        )
        #expect(abs(store.testBundleFlushInterval - 0.1) < 0.0001)

        await store.updateConfiguration(
            .init(snapshotDepth: 4, subtreeDepth: 3, autoUpdateDebounce: 2.0)
        )
        #expect(abs(store.testBundleFlushInterval - 0.2) < 0.0001)
    }

    @Test
    func updateConfigurationAndDepthDispatchDirectlyWhenReady() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testSetReady(true)
        var events: [ReconcileEvent] = []
        store.testConfigurationApplyOverride = { configuration in
            events.append(.configuration(summary(for: configuration)))
        }
        store.testPreferredDepthApplyOverride = { depth in
            events.append(.preferredDepth(depth))
        }

        let configuration = DOMConfiguration(
            snapshotDepth: 8,
            subtreeDepth: 6,
            autoUpdateDebounce: 0.4
        )

        await store.updateConfiguration(configuration)
        await store.setPreferredDepth(9)
        await store.testWaitForBootstrapForTesting()

        #expect(
            events == [
                .configuration(summary(for: configuration)),
                .preferredDepth(9),
            ]
        )
    }

    @Test
    func bootstrapWorkQueuedBeforeReadyReplaysWhenFrontendBecomesReady() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var events: [ReconcileEvent] = []
        var documentRequests: [(depth: Int, mode: DOMDocumentReloadMode)] = []

        store.testConfigurationApplyOverride = { configuration in
            events.append(.configuration(summary(for: configuration)))
        }
        store.testPreferredDepthApplyOverride = { depth in
            events.append(.preferredDepth(depth))
        }
        store.testDocumentRequestApplyOverride = { depth, mode in
            documentRequests.append((depth, mode))
        }

        let configuration = DOMConfiguration(
            snapshotDepth: 8,
            subtreeDepth: 6,
            autoUpdateDebounce: 0.4
        )

        await store.updateConfiguration(configuration)
        await store.setPreferredDepth(9)
        await store.requestDocument(depth: 9, mode: .fresh)

        #expect(events.isEmpty)
        #expect(documentRequests.isEmpty)

        store.testSetReady(true)
        await store.testWaitForBootstrapForTesting()

        #expect(
            events == [
                .configuration(summary(for: configuration)),
                .preferredDepth(9),
            ]
        )
        #expect(documentRequests.count == 1)
        #expect(documentRequests.first?.depth == 9)
        #expect(documentRequests.first?.mode == .fresh)
    }

    @Test
    func currentReadyMessageReplaysBootstrapWork() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var events: [ReconcileEvent] = []
        store.testConfigurationApplyOverride = { configuration in
            events.append(.configuration(summary(for: configuration)))
        }

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: ["pageEpoch": store.currentPageEpoch]
        )
        await store.testWaitForBootstrapForTesting()

        #expect(events.count == 1)
    }

    @Test
    func staleReadyMessageDoesNotReplayBootstrapWork() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var events: [ReconcileEvent] = []
        store.testConfigurationApplyOverride = { configuration in
            events.append(.configuration(summary(for: configuration)))
        }
        await store.performPageTransition(resumeBootstrap: false) { _ in }

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: ["pageEpoch": store.currentPageEpoch - 1]
        )
        await store.testWaitForBootstrapForTesting()

        #expect(events.isEmpty)
    }

    @Test
    func rejectedDocumentRequestDuringTransitionRejectsFrontendRequestWithoutDroppingPendingReload() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        var dispatchedKinds: [String] = []
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if let kind = body["kind"] as? String {
                dispatchedKinds.append(kind)
            }
            return true
        }

        let transitionTask = Task {
            await store.performPageTransition(resumeBootstrap: false) { _ in
                await harness.blockUntilResumed()
            }
        }

        await harness.waitUntilStarted()
        store.bridge.testHandleMessage(
            named: "webInspectorDomRequestDocument",
            body: ["pageEpoch": store.currentPageEpoch, "depth": 4, "mode": "fresh"]
        )

        let didReject = await waitForCondition {
            dispatchedKinds.contains("rejectDocumentRequest")
        }
        #expect(didReject == true)

        await harness.resume()
        await transitionTask.value
    }

    @Test
    func rejectedChildNodeRequestDuringTransitionRejectsFrontendRequestWithoutCompletingQueue() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        var completionPayloads: [[String: Any]] = []
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if body["kind"] as? String == "rejectChildNodeRequest" {
                completionPayloads.append(body)
            }
            return true
        }

        let transitionTask = Task {
            await store.performPageTransition(resumeBootstrap: false) { _ in
                await harness.blockUntilResumed()
            }
        }

        await harness.waitUntilStarted()
        store.bridge.testHandleMessage(
            named: "webInspectorDomRequestChildren",
            body: ["pageEpoch": store.currentPageEpoch, "nodeId": 11, "depth": 2]
        )

        let didReject = await waitForCondition {
            completionPayloads.contains {
                ($0["nodeId"] as? Int) == 11
            }
        }
        #expect(didReject == true)

        await harness.resume()
        await transitionTask.value
    }

    @Test
    func pageTransitionQueuesBootstrapWorkUntilOperationCompletes() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var documentRequests: [(depth: Int, mode: DOMDocumentReloadMode)] = []
        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in }
        store.testPreferredDepthApplyOverride = { _ in }
        store.testDocumentRequestApplyOverride = { depth, mode in
            documentRequests.append((depth, mode))
        }

        await store.performPageTransition { nextPageEpoch in
            await store.requestDocument(depth: 9, mode: .preserveUIState, expectedPageEpoch: nextPageEpoch)
            #expect(documentRequests.isEmpty)
        }
        await store.testWaitForBootstrapForTesting()

        #expect(documentRequests.count == 1)
        #expect(documentRequests.first?.depth == 9)
        #expect(documentRequests.first?.mode == .preserveUIState)
    }

    @Test
    func currentBootstrapPayloadIncludesQueuedPreferredDepthAndDocumentRequest() async {
        let store = makeStore(autoUpdateDebounce: 0.4)

        await store.setPreferredDepth(9)
        await store.requestDocument(depth: 9, mode: .fresh)

        let payload = store.currentBootstrapPayload
        #expect(payload["preferredDepth"] as? Int == 9)
        let request = payload["pendingDocumentRequest"] as? [String: Any]
        #expect(request?["depth"] as? Int == 9)
        #expect(request?["mode"] as? String == "fresh")
        #expect(request?["pageEpoch"] as? Int == store.currentPageEpoch)
    }

    @Test
    func bootstrapPhaseStillAcceptsCurrentEpochProtocolTraffic() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        let configuration = DOMConfiguration(
            snapshotDepth: 8,
            subtreeDepth: 6,
            autoUpdateDebounce: 0.4
        )

        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in
            await harness.blockUntilResumed()
        }

        let bootstrapTask = Task {
            await store.updateConfiguration(configuration)
        }

        await harness.waitUntilStarted()
        #expect(
            store.acceptsFrontendMessage(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            ) == false
        )

        await harness.resume()
        await bootstrapTask.value
        await store.testWaitForBootstrapForTesting()
    }

    @Test
    func domBundlesReplayAfterBootstrapPhaseCompletes() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()

        store.currentDocumentModel.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
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
            )
        )
        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in
            await harness.blockUntilResumed()
        }

        let bootstrapTask = Task {
            await store.updateConfiguration(
                .init(snapshotDepth: 8, subtreeDepth: 6, autoUpdateDebounce: 0.4)
            )
        }

        await harness.waitUntilStarted()
        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.childNodeInserted",
                            "params": [
                                "parentNodeId": 1,
                                "previousNodeId": 0,
                                "node": [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "SPAN",
                                    "localName": "span",
                                    "attributes": [],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )

        #expect(store.currentDocumentModel.rootNode?.children.first == nil)

        await harness.resume()
        await bootstrapTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(store.currentDocumentModel.rootNode?.children.first?.backendNodeID == 2)
    }

    @Test
    func domBundlesQueuedDuringDocumentBootstrapApplyAfterSnapshotReplacement() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()

        store.currentDocumentModel.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [.init(nodeId: 1, name: "class", value: "before")],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                )
            )
        )
        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in }
        store.testDocumentRequestApplyOverride = { _, _ in
            await harness.blockUntilResumed()
            store.currentDocumentModel.replaceDocument(
                with: .init(
                    root: DOMGraphNodeDescriptor(
                        localID: 1,
                        backendNodeID: 1,
                        nodeType: 1,
                        nodeName: "DIV",
                        localName: "div",
                        nodeValue: "",
                        attributes: [.init(nodeId: 1, name: "class", value: "snapshot")],
                        childCount: 0,
                        layoutFlags: [],
                        isRendered: true,
                        children: []
                    )
                )
            )
        }

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .preserveUIState)
        }

        await harness.waitUntilStarted()
        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.attributeModified",
                            "params": [
                                "nodeId": 1,
                                "name": "class",
                                "value": "mutation",
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )

        #expect(store.currentDocumentModel.rootNode?.attributes.first?.value == "before")

        await harness.resume()
        await requestTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(store.currentDocumentModel.rootNode?.attributes.first?.value == "mutation")
    }

    @Test
    func deferredBootstrapReplayContinuesAfterDocumentUpdatedBoundary() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()

        store.currentDocumentModel.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [.init(nodeId: 1, name: "class", value: "before")],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                )
            )
        )
        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in
            await harness.blockUntilResumed()
        }

        let bootstrapTask = Task {
            await store.updateConfiguration(
                .init(snapshotDepth: 8, subtreeDepth: 6, autoUpdateDebounce: 0.4)
            )
        }

        await harness.waitUntilStarted()
        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.documentUpdated",
                            "params": [:],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )
        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "snapshot": [
                        "root": [
                            "nodeId": 7,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": ["class", "after"],
                            "children": [],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )

        await harness.resume()
        await bootstrapTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(store.currentDocumentModel.rootNode?.backendNodeID == 7)
        #expect(store.currentDocumentModel.rootNode?.attributes.first?.value == "after")
    }

    @Test
    func domBundlesRelayToFrontendAndUpdateCurrentDocumentStore() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "snapshot": [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": [],
                            "children": [],
                        ],
                    ],
                ]
            )
        )

        #expect(store.pendingMutationBundleCount == 1)
        #expect(store.currentDocumentModel.rootNode?.backendNodeID == 1)
        #expect(store.currentDocumentModel.selectedNode == nil)
    }

    @Test
    func preserveSnapshotDoesNotAdvanceDocumentScope() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "snapshot": [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": [],
                            "children": [],
                        ],
                    ],
                ]
            )
        )

        let initialDocumentScopeID = store.currentDocumentScopeID

        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "manual",
                    "snapshot": [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": ["class", "updated"],
                            "children": [],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialDocumentScopeID
            )
        )

        #expect(store.currentDocumentScopeID == initialDocumentScopeID)
        #expect(store.currentDocumentModel.rootNode?.attributes.first?.name == "class")
        #expect(store.currentDocumentModel.rootNode?.attributes.first?.value == "updated")
    }

    @Test
    func mutationFlushRebasesObjectEnvelopeToCurrentContextAndDropsPostDocumentUpdatedEvents() async {
        let store = makeStore(autoUpdateDebounce: 0.01)
        let initialPageEpoch = store.currentPageEpoch
        let initialScopeID = store.currentDocumentScopeID
        store.testAdvanceCurrentDocumentScopeWithoutClearingModel()

        let rebasedBundle = store.testBundleForFrontend(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "pageEpoch": initialPageEpoch,
                    "documentScopeID": initialScopeID,
                    "events": [
                        [
                            "method": "DOM.documentUpdated",
                            "params": [:],
                        ],
                        [
                            "method": "DOM.attributeModified",
                            "params": [
                                "nodeId": 1,
                                "name": "class",
                                "value": "after",
                            ],
                        ],
                    ],
                ],
                pageEpoch: initialPageEpoch,
                documentScopeID: initialScopeID
            )
        )
        #expect(store.currentDocumentScopeID > initialScopeID)
        #expect(rebasedBundle.pageEpoch == store.currentPageEpoch)
        #expect(rebasedBundle.documentScopeID == store.currentDocumentScopeID)
        let embeddedPayload = rebasedBundle.objectEnvelope as? [String: Any]
        #expect(embeddedPayload?["pageEpoch"] as? Int == store.currentPageEpoch)
        #expect(embeddedPayload?["documentScopeID"] as? UInt64 == store.currentDocumentScopeID)
        let events = embeddedPayload?["events"] as? [[String: Any]]
        #expect(events?.count == 1)
        #expect(events?.first?["method"] as? String == "DOM.documentUpdated")
    }

    @Test
    func mutationFlushRebasesRawJSONPayloadToCurrentContext() async {
        let store = makeStore(autoUpdateDebounce: 0.01)
        let initialPageEpoch = store.currentPageEpoch
        let initialScopeID = store.currentDocumentScopeID
        store.testAdvanceCurrentDocumentScopeWithoutClearingModel()
        let rawPayload = """
        {
          "version": 1,
          "kind": "mutation",
          "pageEpoch": \(initialPageEpoch),
          "documentScopeID": \(initialScopeID),
          "events": [
            {
              "method": "DOM.documentUpdated",
              "params": {}
            }
          ]
        }
        """
        let rebasedBundle = store.testBundleForFrontend(
            .init(
                rawJSON: rawPayload,
                pageEpoch: initialPageEpoch,
                documentScopeID: initialScopeID
            )
        )
        #expect(store.currentDocumentScopeID > initialScopeID)
        let embeddedPayload = rebasedBundle.objectEnvelope as? [String: Any]
        #expect(rebasedBundle.pageEpoch == store.currentPageEpoch)
        #expect(rebasedBundle.documentScopeID == store.currentDocumentScopeID)
        #expect(embeddedPayload?["pageEpoch"] as? Int == store.currentPageEpoch)
        #expect(embeddedPayload?["documentScopeID"] as? UInt64 == store.currentDocumentScopeID)
    }

    @Test
    func resetMarkedSnapshotClearsPreviousProjectionBeforeApply() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        store.currentDocumentModel.setErrorMessage("stale")

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "snapshot": [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )

        #expect(store.currentDocumentModel.rootNode?.backendNodeID == 1)
        #expect(store.currentDocumentModel.selectedNode == nil)
        #expect(store.currentDocumentModel.errorMessage == nil)
    }


    @Test
    func requestDocumentWithoutPreserveStateClearsExistingProjection() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testSetReady(true)

        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        await store.requestDocument(depth: 4, mode: .fresh)

        #expect(store.currentDocumentModel.selectedNode == nil)
    }

    @Test
    func freshRequestDocumentWaitsForInFlightMutationFlushBeforeClearingProjection() async {
        let store = makeStore(autoUpdateDebounce: 0.01)
        let harness = BootstrapHarness()
        store.testConfigurationApplyOverride = { _ in }
        store.testSetReady(true)
        await store.testWaitForBootstrapForTesting()
        store.testBeforeMutationDispatchOverride = {
            await harness.blockUntilResumed()
        }
        store.testMutationFlushOverride = { _ in }

        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        let initialProjectedPageEpoch = store.currentPageEpoch
        let initialProjectedScopeID = store.currentDocumentScopeID

        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)
        let flushDidStart = await waitForCondition {
            store.testHasActiveBundleFlushTask
        }
        #expect(flushDidStart == true)
        await harness.waitUntilStarted()

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .fresh)
        }

        #expect(store.currentDocumentModel.selectedNode != nil)
        #expect(store.currentPageEpoch == initialProjectedPageEpoch)
        #expect(store.currentDocumentScopeID == initialProjectedScopeID)

        await harness.resume()
        await requestTask.value

        #expect(store.currentDocumentModel.selectedNode == nil)
        #expect(store.currentPageEpoch == initialProjectedPageEpoch)
        #expect(store.currentDocumentScopeID == initialProjectedScopeID + 1)
    }

    @Test
    func pageTransitionClearsProjectionAndPendingMutationBundles() async {
        let store = makeStore(autoUpdateDebounce: 0.01)
        store.testSetReady(true)
        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        await store.performPageTransition(resumeBootstrap: false) { _ in }

        #expect(store.pendingMutationBundleCount == 0)
        #expect(store.currentDocumentModel.selectedNode == nil)
        #expect(store.testCompletedMutationGeneration == 0)
    }

    @Test
    func freshRequestDocumentAbortAfterPageTransitionDoesNotCommitStaleProjectedContext() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        var resetRequestCount = 0
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if body["kind"] as? String == "resetChildNodeRequests" {
                resetRequestCount += 1
                await harness.blockUntilResumed()
            }
            return true
        }
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .fresh)
        }

        await harness.waitUntilStarted()
        let transitionedPageEpoch = await store.performPageTransition(resumeBootstrap: false) { nextPageEpoch in
            nextPageEpoch
        }
        let transitionedScopeID = store.currentDocumentScopeID
        #expect(store.currentPageEpoch == transitionedPageEpoch)
        #expect(store.currentDocumentModel.selectedNode == nil)

        await harness.resume()
        await requestTask.value

        #expect(resetRequestCount == 1)
        #expect(store.currentPageEpoch == transitionedPageEpoch)
        #expect(store.currentDocumentScopeID == transitionedScopeID)
        #expect(store.currentDocumentModel.selectedNode == nil)
    }

    @Test
    func pageSwitchCancelsInFlightBootstrapBeforeFollowUpStepsRun() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        let configuration = DOMConfiguration(
            snapshotDepth: 8,
            subtreeDepth: 6,
            autoUpdateDebounce: 0.4
        )
        var didBlockInitialConfigurationPass = false
        var preferredDepths: [Int] = []
        var documentRequests: [(depth: Int, mode: DOMDocumentReloadMode)] = []

        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in
            if didBlockInitialConfigurationPass == false {
                didBlockInitialConfigurationPass = true
                await harness.blockUntilResumed()
            }
        }
        store.testPreferredDepthApplyOverride = { depth in
            preferredDepths.append(depth)
        }
        store.testDocumentRequestApplyOverride = { depth, mode in
            documentRequests.append((depth, mode))
        }

        let bootstrapTask = Task {
            let expectedPageEpoch = store.currentPageEpoch
            await store.updateConfiguration(configuration, expectedPageEpoch: expectedPageEpoch)
            await store.setPreferredDepth(9, expectedPageEpoch: expectedPageEpoch)
            await store.requestDocument(depth: 9, mode: .fresh, expectedPageEpoch: expectedPageEpoch)
        }

        await harness.waitUntilStarted()
        await store.performPageTransition(resumeBootstrap: false) { _ in }
        await harness.resume()
        await bootstrapTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(preferredDepths.isEmpty)
        #expect(documentRequests.isEmpty)
    }

    @Test
    func enqueueMutationBundleWhileNotReadyDoesNotScheduleFlush() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)

        #expect(store.pendingMutationBundleCount == 1)
        #expect(store.testHasPendingBundleFlushTask == false)
    }

    @Test
    func clearPendingMutationBundlesCancelsScheduledFlushWhenReady() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testConfigurationApplyOverride = { _ in }
        store.testSetReady(true)
        await store.testWaitForBootstrapForTesting()

        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)
        #expect(store.pendingMutationBundleCount == 1)
        #expect(store.testHasPendingBundleFlushTask == true)

        store.clearPendingMutationBundles()
        #expect(store.pendingMutationBundleCount == 0)
        #expect(store.testHasPendingBundleFlushTask == false)
    }

    @Test
    func staleExpectedPageEpochDocumentRequestReturnsFalse() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let stalePageEpoch = store.currentPageEpoch

        await store.performPageTransition(resumeBootstrap: false) { _ in }

        let didRequestDocument = await store.requestDocument(
            depth: 4,
            mode: .fresh,
            expectedPageEpoch: stalePageEpoch
        )

        #expect(didRequestDocument == false)
    }

    @Test
    func requestDocumentWithoutWebViewClearsExistingGraphProjection() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testSetReady(true)

        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        await store.requestDocument(depth: 4, mode: .fresh)

        #expect(store.currentDocumentModel.selectedNode == nil)
    }

    @Test
    func requestDocumentWithoutPreserveStateDropsQueuedMutationBundles() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)

        await store.requestDocument(depth: 4, mode: .fresh)

        #expect(store.pendingMutationBundleCount == 0)
    }

    @Test
    func freshRequestDocumentResetsFrontendChildNodeRequests() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var resetPayloads: [[String: Any]] = []
        let currentDocumentScopeID = store.currentDocumentScopeID
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if body["kind"] as? String == "resetChildNodeRequests" {
                resetPayloads.append(body)
            }
            return true
        }

        await store.requestDocument(depth: 4, mode: .fresh)

        #expect(resetPayloads.count == 1)
        #expect(resetPayloads.first?["documentScopeID"] as? UInt64 == currentDocumentScopeID)
    }

    @Test
    func freshRequestDocumentAbortsWhenFrontendChildNodeResetFails() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var dispatchedKinds: [String] = []
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if let kind = body["kind"] as? String {
                dispatchedKinds.append(kind)
                if kind == "resetChildNodeRequests" {
                    return false
                }
            }
            return true
        }
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        let initialProjectedPageEpoch = store.currentPageEpoch
        let initialProjectedScopeID = store.currentDocumentScopeID

        let didRequestDocument = await store.requestDocument(depth: 4, mode: .fresh)

        #expect(didRequestDocument == false)
        #expect(dispatchedKinds == ["resetChildNodeRequests"])
        #expect(store.currentPageEpoch == initialProjectedPageEpoch)
        #expect(store.currentDocumentScopeID == initialProjectedScopeID)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 42)
    }

    @Test
    func freshRequestDocumentResetFailurePreservesQueuedMutationBundles() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            return body["kind"] as? String != "resetChildNodeRequests"
        }
        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)

        await store.requestDocument(depth: 4, mode: .fresh)

        #expect(store.pendingMutationBundleCount == 1)
    }

    @Test
    func freshRequestDocumentResetFailurePreservesDeferredBootstrapDOMBundles() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let initialScopeID = store.currentDocumentScopeID
        var didStartConfigurationPass = false
        var allowConfigurationPassToFinish = false

        replaceDocument(in: store, root: makeNode(localID: 1))

        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in
            didStartConfigurationPass = true
            while allowConfigurationPassToFinish == false, Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            return body["kind"] as? String != "resetChildNodeRequests"
        }

        let bootstrapTask = Task {
            await store.updateConfiguration(
                .init(snapshotDepth: 8, subtreeDepth: 6, autoUpdateDebounce: 0.4)
            )
        }

        let didStartBootstrap = await waitForCondition {
            didStartConfigurationPass
        }
        #expect(didStartBootstrap == true)
        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.childNodeInserted",
                            "params": [
                                "parentNodeId": 1,
                                "previousNodeId": 0,
                                "node": [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "SPAN",
                                    "localName": "span",
                                    "attributes": [],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        let didRequestDocument = await store.requestDocument(depth: 4, mode: .fresh)

        allowConfigurationPassToFinish = true
        await bootstrapTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(didRequestDocument == false)
        #expect(store.currentDocumentModel.rootNode?.children.map(\.backendNodeID) == [2])
    }


    @Test
    func documentRequestFailureRejectsFrontendRequest() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var dispatchedKinds: [String] = []
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if let kind = body["kind"] as? String {
                dispatchedKinds.append(kind)
                if kind == "resetChildNodeRequests" {
                    return false
                }
            }
            return true
        }

        store.handleDocumentRequestMessage([
            "depth": 4,
            "mode": DOMDocumentReloadMode.fresh.rawValue,
        ])

        let didReject = await waitForCondition {
            dispatchedKinds.contains("rejectDocumentRequest")
        }
        #expect(didReject == true)
    }

    @Test
    func staleDocumentScopeRequestIsRejected() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var dispatchedKinds: [String] = []
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if let kind = body["kind"] as? String {
                dispatchedKinds.append(kind)
            }
            return true
        }
        store.testDocumentScopeSyncOverride = { _ in }

        let didRequest = await store.requestDocument(depth: 4, mode: .fresh)
        #expect(didRequest == true)
        let currentScopeID = store.currentDocumentScopeID
        #expect(currentScopeID > 0)

        store.handleDocumentRequestMessage([
            "depth": 4,
            "mode": DOMDocumentReloadMode.fresh.rawValue,
            "documentScopeID": currentScopeID - 1,
        ])

        let didReject = await waitForCondition {
            dispatchedKinds.contains("rejectDocumentRequest")
        }
        #expect(didReject == true)
    }

    @Test
    func staleInitialSnapshotScopeDoesNotRewindCurrentDocumentScope() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.currentDocumentModel.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 101,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [.init(nodeId: 101, name: "class", value: "current")],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                )
            )
        )
        store.testAdvanceCurrentDocumentScopeWithoutClearingModel()
        let currentScopeID = store.currentDocumentScopeID

        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "snapshotMode": "fresh",
                    "snapshot": [
                        "root": [
                            "nodeId": 7,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": ["class", "stale"],
                            "children": [],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: currentScopeID - 1
            )
        )

        #expect(store.currentDocumentScopeID == currentScopeID)
        #expect(store.currentDocumentModel.rootNode?.backendNodeID == 101)
        #expect(store.currentDocumentModel.rootNode?.attributes.first?.value == "current")
    }

    @Test
    func freshRequestDocumentPreservesProjectedContextUntilScopeSyncCompletes() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let syncHarness = BootstrapHarness()
        store.testFrontendDispatchOverride = { _ in true }
        store.testDocumentScopeSyncOverride = { _ in
            await syncHarness.blockUntilResumed()
        }
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        let initialProjectedPageEpoch = store.currentPageEpoch
        let initialProjectedScopeID = store.currentDocumentScopeID
        let initialSelectedBackendNodeID = store.currentDocumentModel.selectedNode?.backendNodeID

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .fresh)
        }
        await syncHarness.waitUntilStarted()

        #expect(store.currentPageEpoch == initialProjectedPageEpoch)
        #expect(store.currentDocumentScopeID == initialProjectedScopeID)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == initialSelectedBackendNodeID)

        await syncHarness.resume()
        _ = await requestTask.value
    }

    @Test
    func initialSnapshotClearsPendingUndoSelectionOverride() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.setPendingSelectionOverride(localID: 42)
        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "snapshot": [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": []
                        ]
                    ]
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            )
        )

        #expect(store.testPendingSelectionOverrideLocalID == nil)
    }

    @Test
    func initialSnapshotWithExistingDocumentPreservesDocumentScopeWithoutReplacementFence() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        replaceDocument(
            in: store,
            root: makeNode(
                localID: 1,
                nodeName: "HTML",
                localName: "html",
                children: [
                    makeNode(
                        localID: 2,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [.init(nodeId: 2, name: "id", value: "body")]
                    ),
                ]
            ),
            selectedLocalID: 2
        )
        let initialScopeID = store.currentDocumentScopeID

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "snapshot": [
                        "selectedNodeId": 2,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "body", "class", "same-page"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        #expect(store.currentDocumentScopeID == initialScopeID)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 2)
        #expect(
            store.currentDocumentModel.selectedNode?.attributes.contains {
                $0.name == "class" && $0.value == "same-page"
            } == true
        )
    }

    @Test
    func sameDocumentInitialSnapshotDoesNotAdvanceScope() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        replaceDocument(
            in: store,
            root: makeNode(
                localID: 1,
                nodeName: "HTML",
                localName: "html",
                children: [
                    makeNode(
                        localID: 2,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [.init(nodeId: 2, name: "id", value: "page-one")]
                    ),
                ]
            ),
            selectedLocalID: 2
        )

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "documentURL": "https://example.com/page-one",
                    "snapshot": [
                        "selectedNodeId": 2,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-one"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            )
        )
        let initialScopeID = store.currentDocumentScopeID

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "documentURL": "https://example.com/page-one",
                    "snapshot": [
                        "selectedNodeId": 2,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-one", "class", "preserved"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        #expect(store.currentDocumentScopeID == initialScopeID)
        #expect(
            store.currentDocumentModel.selectedNode?.attributes.contains {
                $0.name == "class" && $0.value == "preserved"
            } == true
        )
    }

    @Test
    func adoptPageContextIgnoresHashOnlyDocumentURLChanges() async {
        let store = makeStore(autoUpdateDebounce: 0.4)

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "documentURL": "https://example.com/page-one#first",
                    "snapshot": [
                        "selectedNodeId": 2,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-one"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            )
        )

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID,
                documentURL: "https://example.com/page-one#second"
            )
        )

        #expect(didAdopt == false)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 2)
    }

    @Test
    func sameContextFreshSnapshotDoesNotAdvanceDocumentScope() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        replaceDocument(
            in: store,
            root: makeNode(
                localID: 1,
                nodeName: "HTML",
                localName: "html",
                children: [
                    makeNode(
                        localID: 2,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [.init(nodeId: 2, name: "id", value: "page-one")]
                    ),
                ]
            ),
            selectedLocalID: 2
        )
        let initialScopeID = store.currentDocumentScopeID

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "snapshotMode": "fresh",
                    "snapshot": [
                        "selectedNodeId": 2,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-one", "class", "fresh-same-context"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        #expect(store.currentDocumentScopeID == initialScopeID)
        #expect(
            store.currentDocumentModel.selectedNode?.attributes.contains {
                $0.name == "class" && $0.value == "fresh-same-context"
            } == true
        )
    }

    @Test
    func selectionSnapshotModePreservesCurrentDocumentContext() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        replaceDocument(
            in: store,
            root: makeNode(
                localID: 1,
                nodeName: "HTML",
                localName: "html",
                children: [
                    makeNode(
                        localID: 2,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [.init(nodeId: 2, name: "id", value: "before")]
                    ),
                ]
            )
        )
        let initialScopeID = store.currentDocumentScopeID

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "selection",
                    "snapshotMode": "preserve-ui-state",
                    "snapshot": [
                        "selectedNodeId": 3,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "before"],
                                    "children": [
                                        [
                                            "nodeId": 3,
                                            "nodeType": 1,
                                            "nodeName": "DIV",
                                            "localName": "div",
                                            "attributes": ["id", "target"],
                                            "children": [],
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        #expect(store.currentDocumentScopeID == initialScopeID)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 3)
    }

    @Test
    func runtimeDoesNotDropSelectionFollowupMutationsForSameContext() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let initialScopeID = store.currentDocumentScopeID

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "selection",
                    "snapshotMode": "preserve-ui-state",
                    "snapshot": [
                        "selectedNodeId": 2,
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "body"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.childNodeInserted",
                            "params": [
                                "parentNodeId": 2,
                                "previousNodeId": 0,
                                "node": [
                                    "nodeId": 3,
                                    "nodeType": 1,
                                    "nodeName": "DIV",
                                    "localName": "div",
                                    "attributes": ["id", "after-selection"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        #expect(store.currentDocumentScopeID == initialScopeID)
        #expect(
            store.currentDocumentModel.rootNode?.children.first?.children.contains {
                $0.attributes.contains(where: { $0.name == "id" && $0.value == "after-selection" })
            } == true
        )
    }

    @Test
    func initialSnapshotWithDifferentDocumentURLAndOlderScopeReplacesCurrentTree() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "documentURL": "https://example.com/page-two",
                    "snapshot": [
                        "root": [
                            "nodeId": 1,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-two"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            )
        )

        let staleDocumentScopeID = store.currentDocumentScopeID
        store.testAdvanceCurrentDocumentScopeWithoutClearingModel()

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "documentURL": "https://example.com/page-one",
                    "snapshot": [
                        "root": [
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 11,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-one"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: staleDocumentScopeID
            )
        )

        #expect(store.currentDocumentScopeID == staleDocumentScopeID)
        #expect(
            store.currentDocumentModel.rootNode?.children.contains {
                $0.attributes.contains(where: { $0.name == "id" && $0.value == "page-one" })
            } == true
        )
        #expect(
            store.currentDocumentModel.rootNode?.children.contains {
                $0.attributes.contains(where: { $0.name == "id" && $0.value == "page-two" })
            } == false
        )
    }

    @Test
    func freshRequestDocumentClearsPendingUndoSelectionOverride() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testFrontendDispatchOverride = { _ in true }
        store.testDocumentScopeSyncOverride = { _ in }
        store.setPendingSelectionOverride(localID: 42)

        let didRequestDocument = await store.requestDocument(depth: 4, mode: .fresh)

        #expect(didRequestDocument == true)
        #expect(store.testPendingSelectionOverrideLocalID == nil)
    }

    @Test
    func adoptPageContextPreservesSelectionStateWhenRequested() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        store.setPendingSelectionOverride(localID: 42)

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )

        #expect(didAdopt == true)
        #expect(store.currentPageEpoch == 4)
        #expect(store.currentDocumentScopeID == 6)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 42)
        #expect(store.testPendingSelectionOverrideLocalID == 42)
    }

    @Test
    func adoptPageContextClearsQueuedDocumentRequest() async {
        let store = makeStore(autoUpdateDebounce: 0.4)

        _ = await store.requestDocument(depth: 4, mode: .fresh)
        #expect(store.currentBootstrapPayload["pendingDocumentRequest"] != nil)

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6)
        )

        #expect(didAdopt == true)
        #expect(store.currentBootstrapPayload["pendingDocumentRequest"] == nil)
    }

    @Test
    func undoSelectionRestoreUsesSelectedNodeLocalID() {
        let inspector = WIInspectorController().dom
        let selectedLocalID: UInt64 = 42
        let selectedBackendNodeID = 77
        inspector.document.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
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
                            localID: selectedLocalID,
                            backendNodeID: selectedBackendNodeID,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [.init(nodeId: selectedBackendNodeID, name: "id", value: "target")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                ),
                selectedLocalID: selectedLocalID
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: selectedBackendNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let payload = inspector.testSelectionRestorePayload(for: selectedBackendNodeID)
        inspector.transport.setPendingSelectionOverride(localID: payload?.localID)

        #expect(payload?.localID == selectedLocalID)
        #expect(inspector.transport.testPendingSelectionOverrideLocalID == selectedLocalID)
    }

    @Test
    func deleteSelectionDoesNotPruneModelAfterMutationContextChangesMidFlight() async {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 7, attributes: [.init(nodeId: 7, name: "id", value: "target")])]
                ),
                selectedLocalID: 7
            )
        )
        inspector.session.testRemoveNodeOverride = { _, _, _ in
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
            return .applied(())
        }

        let result = await inspector.deleteSelection()

        #expect(result == .applied)
        #expect(inspector.document.selectedNode?.backendNodeID == 7)
        #expect(inspector.document.node(backendNodeID: 7) != nil)
    }

    @Test
    func redoDeleteUsesOriginalLocalIDForDetachedSelectionPlaceholder() async {
        let inspector = WIInspectorController().dom
        let undoManager = UndoManager()
        let removedLocalID: UInt64 = 7
        let removedBackendNodeID = 42
        let decoyLocalID: UInt64 = 42
        let undoToken = 99

        inspector.document.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
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
                            localID: decoyLocalID,
                            backendNodeID: 9001,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [.init(nodeId: 9001, name: "id", value: "decoy")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: removedLocalID,
                backendNodeID: removedBackendNodeID,
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: removedBackendNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        inspector.session.testRemoveNodeWithUndoOverride = { target, _, _ in
            #expect(target == .backend(removedBackendNodeID))
            return .applied(undoToken)
        }
        inspector.session.testUndoRemoveNodeInterposer = { receivedUndoToken, _, _, _ in
            #expect(receivedUndoToken == undoToken)
            return .applied(())
        }
        inspector.session.testRedoRemoveNodeInterposer = { receivedUndoToken, nodeId, _, _, _ in
            #expect(receivedUndoToken == undoToken)
            #expect(nodeId == removedBackendNodeID)
            return .applied(())
        }

        let deleteResult = await inspector.deleteSelection(undoManager: undoManager)

        #expect(deleteResult == .applied)
        #expect(inspector.document.node(localID: removedLocalID) == nil)
        #expect(inspector.document.node(localID: decoyLocalID)?.backendNodeID == 9001)

        undoManager.undo()

        let didRestoreRemovedSelection = await waitForCondition {
            inspector.document.selectedNode?.localID == removedLocalID
        }

        #expect(didRestoreRemovedSelection == true)
        #expect(inspector.document.node(localID: removedLocalID)?.backendNodeID == removedBackendNodeID)
        #expect(inspector.document.node(localID: decoyLocalID)?.backendNodeID == 9001)

        undoManager.redo()

        let didRemoveRestoredSelection = await waitForCondition {
            inspector.document.node(localID: removedLocalID) == nil
        }

        #expect(didRemoveRestoredSelection == true)
        #expect(inspector.document.node(localID: decoyLocalID)?.backendNodeID == 9001)
        #expect(inspector.document.selectedNode == nil)
    }

    @Test
    func staleReloadClearsPendingSelectionOverride() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        await inspector.attach(to: webView)
        var didRequestDocument = false
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testPreferredDepthApplyOverride = { _ in
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
        }
        inspector.transport.testDocumentRequestApplyOverride = { _, _ in
            didRequestDocument = true
        }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()
        didRequestDocument = false

        inspector.transport.setPendingSelectionOverride(localID: 42)

        let result = await inspector.reloadDocumentPreservingInspectorState()

        #expect(result == .ignoredStaleContext)
        #expect(didRequestDocument == false)
        #expect(inspector.transport.testPendingSelectionOverrideLocalID == nil)
    }

    @Test
    func adoptPageContextDefersDOMBundlesUntilReplacementRequestDispatches() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        store.testConfigurationApplyOverride = { _ in }
        await drainInitialBootstrapWork(store)
        store.testDocumentRequestApplyOverride = { _, _ in
            await harness.blockUntilResumed()
        }

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(didAdopt == true)
        #expect(store.acceptsDOMBundle(documentScopeID: 6) == false)

        let requestTask = Task {
            await store.requestDocument(
                depth: 4,
                mode: .preserveUIState,
                expectedPageEpoch: store.currentPageEpoch,
                expectedDocumentScopeID: store.currentDocumentScopeID
            )
        }

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        await harness.waitUntilStarted()
        #expect(store.acceptsDOMBundle(documentScopeID: store.currentDocumentScopeID) == false)
        await harness.resume()
        let didRequestDocument = await requestTask.value
        #expect(store.acceptsDOMBundle(documentScopeID: store.currentDocumentScopeID) == true)
        #expect(didRequestDocument == true)
    }

    @Test
    func adoptPageContextDefersFrontendMessagesUntilReplacementRequestDispatches() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        store.testConfigurationApplyOverride = { _ in }
        await drainInitialBootstrapWork(store)
        store.testDocumentRequestApplyOverride = { _, _ in
            await harness.blockUntilResumed()
        }

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(didAdopt == true)
        #expect(
            store.acceptsFrontendMessage(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            ) == false
        )

        let requestTask = Task {
            await store.requestDocument(
                depth: 4,
                mode: .preserveUIState,
                expectedPageEpoch: store.currentPageEpoch,
                expectedDocumentScopeID: store.currentDocumentScopeID
            )
        }

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        await harness.waitUntilStarted()
        #expect(
            store.acceptsFrontendMessage(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            ) == false
        )
        await harness.resume()
        let didRequestDocument = await requestTask.value
        #expect(
            store.acceptsFrontendMessage(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            ) == true
        )
        #expect(didRequestDocument == true)
    }

    @Test
    func adoptPageContextBlocksHighlightMessagesUntilReplacementRequestDispatches() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var highlightedNodeIDs: [Int] = []
        store.testConfigurationApplyOverride = { _ in }
        store.testDocumentRequestApplyOverride = { _, _ in }
        store.session.testHighlightOverride = { nodeID, _ in
            highlightedNodeIDs.append(nodeID)
        }
        await drainInitialBootstrapWork(store)

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(didAdopt == true)

        store.bridge.testHandleMessage(
            named: "webInspectorDomHighlight",
            body: [
                "nodeId": 42,
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        let didHighlightDuringFence = await waitForCondition(maxAttempts: 5) {
            highlightedNodeIDs.isEmpty == false
        }
        #expect(didHighlightDuringFence == false)

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        let didRequestDocument = await store.requestDocument(
            depth: 4,
            mode: .preserveUIState,
            expectedPageEpoch: store.currentPageEpoch,
            expectedDocumentScopeID: store.currentDocumentScopeID
        )
        #expect(didRequestDocument == true)

        store.bridge.testHandleMessage(
            named: "webInspectorDomHighlight",
            body: [
                "nodeId": 42,
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        let didHighlightAfterReplacement = await waitForCondition(maxAttempts: 5) {
            highlightedNodeIDs == [42]
        }
        #expect(didHighlightAfterReplacement == true)
    }

    @Test
    func highlightMessagePreservesRevealIntentFromFrontendPayload() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var highlightedRequests: [(nodeID: Int, reveal: Bool)] = []
        store.session.testHighlightOverride = { nodeID, reveal in
            highlightedRequests.append((nodeID, reveal))
        }
        await drainInitialBootstrapWork(store)

        store.bridge.testHandleMessage(
            named: "webInspectorDomHighlight",
            body: [
                "nodeId": 42,
                "reveal": false,
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )

        let didReceiveHighlight = await waitForCondition(maxAttempts: 5) {
            highlightedRequests.count == 1
        }

        #expect(didReceiveHighlight == true)
        #expect(highlightedRequests.map(\.nodeID) == [42])
        #expect(highlightedRequests.map(\.reveal) == [false])
    }

    @Test
    func rejectedDocumentRequestDuringContextAdoptionDrainsAfterLaterReplacementDispatch() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var dispatchedKinds: [String] = []
        store.testConfigurationApplyOverride = { _ in }
        store.testDocumentRequestApplyOverride = { _, _ in }
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if let kind = body["kind"] as? String {
                dispatchedKinds.append(kind)
            }
            return true
        }
        await drainInitialBootstrapWork(store)

        let firstAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(firstAdopt == true)

        store.bridge.testHandleMessage(
            named: "webInspectorDomRequestDocument",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
                "depth": 4,
                "mode": DOMDocumentReloadMode.preserveUIState.rawValue,
            ]
        )
        let didReject = await waitForCondition(maxAttempts: 5) {
            dispatchedKinds.contains("rejectDocumentRequest")
        }
        #expect(didReject == true)

        let secondAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 5, documentScopeID: 7),
            preserveCurrentDocumentState: true
        )
        #expect(secondAdopt == true)

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        let didRequestDocument = await store.requestDocument(
            depth: 4,
            mode: .preserveUIState,
            expectedPageEpoch: store.currentPageEpoch,
            expectedDocumentScopeID: store.currentDocumentScopeID
        )
        #expect(didRequestDocument == true)

        let didComplete = await waitForCondition(maxAttempts: 5) {
            dispatchedKinds.contains("completeDocumentRequest")
        }
        #expect(didComplete == true)
    }

    @Test
    func rejectedChildNodeRequestDuringContextAdoptionDrainsAfterLaterReplacementDispatch() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var retryPayloads: [[String: Any]] = []
        store.testConfigurationApplyOverride = { _ in }
        store.testDocumentRequestApplyOverride = { _, _ in }
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if body["kind"] as? String == "retryQueuedChildNodeRequests" {
                retryPayloads.append(body)
            }
            return true
        }
        await drainInitialBootstrapWork(store)

        let firstAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(firstAdopt == true)

        store.bridge.testHandleMessage(
            named: "webInspectorDomRequestChildren",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
                "nodeId": 11,
                "depth": 2,
            ]
        )

        let secondAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 5, documentScopeID: 7),
            preserveCurrentDocumentState: true
        )
        #expect(secondAdopt == true)

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        let didRequestDocument = await store.requestDocument(
            depth: 4,
            mode: .preserveUIState,
            expectedPageEpoch: store.currentPageEpoch,
            expectedDocumentScopeID: store.currentDocumentScopeID
        )
        #expect(didRequestDocument == true)

        let didRetry = await waitForCondition(maxAttempts: 5) {
            retryPayloads.contains {
                ($0["pageEpoch"] as? Int) == store.currentPageEpoch
                    && ($0["documentScopeID"] as? UInt64) == store.currentDocumentScopeID
            }
        }
        #expect(didRetry == true)
    }

    @Test
    func adoptPageContextPreservesReadyMessageUntilReplacementRequestDispatches() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        var documentRequestCount = 0
        store.testConfigurationApplyOverride = { _ in }
        await drainInitialBootstrapWork(store)
        store.testDocumentRequestApplyOverride = { _, _ in
            documentRequestCount += 1
            await harness.blockUntilResumed()
        }

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(didAdopt == true)
        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        await store.testWaitForBootstrapForTesting()
        #expect(documentRequestCount == 0)

        let requestTask = Task {
            await store.requestDocument(
                depth: 4,
                mode: .preserveUIState,
                expectedPageEpoch: store.currentPageEpoch,
                expectedDocumentScopeID: store.currentDocumentScopeID
            )
        }
        await harness.waitUntilStarted()
        #expect(documentRequestCount == 1)
        #expect(
            store.acceptsFrontendMessage(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            ) == false
        )
        await harness.resume()
        let didRequestDocument = await requestTask.value
        #expect(didRequestDocument == true)
        #expect(
            store.acceptsFrontendMessage(
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            ) == true
        )
    }

    @Test
    func adoptPageContextRebasesDeferredReadyAfterLaterContextAdoption() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        var documentRequestCount = 0
        store.testConfigurationApplyOverride = { _ in }
        await drainInitialBootstrapWork(store)
        store.testDocumentRequestApplyOverride = { _, _ in
            documentRequestCount += 1
            await harness.blockUntilResumed()
        }

        let firstAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(firstAdopt == true)
        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        await store.testWaitForBootstrapForTesting()
        #expect(documentRequestCount == 0)

        let secondAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 5, documentScopeID: 7),
            preserveCurrentDocumentState: true
        )
        #expect(secondAdopt == true)

        let requestTask = Task {
            await store.requestDocument(
                depth: 4,
                mode: .preserveUIState,
                expectedPageEpoch: store.currentPageEpoch,
                expectedDocumentScopeID: store.currentDocumentScopeID
            )
        }

        await harness.waitUntilStarted()
        #expect(documentRequestCount == 1)
        await harness.resume()
        let didRequestDocument = await requestTask.value
        #expect(didRequestDocument == true)
        await store.testWaitForBootstrapForTesting()
    }

    @Test
    func replacementRetryAfterContextAdoptionKeepsRequestedDocumentMode() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()
        store.testConfigurationApplyOverride = { _ in }
        await drainInitialBootstrapWork(store)
        store.testDocumentRequestApplyOverride = { _, _ in
            await harness.blockUntilResumed()
        }

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(didAdopt == true)
        #expect(store.currentBootstrapPayload["pendingDocumentRequest"] == nil)
        #expect(store.acceptsDOMBundle(documentScopeID: store.currentDocumentScopeID) == false)

        store.retryDocumentReplacementAfterContextAdoption(depth: 5, mode: .fresh)

        let request = store.currentBootstrapPayload["pendingDocumentRequest"] as? [String: Any]
        #expect(request?["depth"] as? Int == 5)
        #expect(request?["mode"] as? String == DOMDocumentReloadMode.fresh.rawValue)
        #expect(store.acceptsDOMBundle(documentScopeID: store.currentDocumentScopeID) == false)

        store.bridge.testHandleMessage(
            named: "webInspectorReady",
            body: [
                "pageEpoch": store.currentPageEpoch,
                "documentScopeID": store.currentDocumentScopeID,
            ]
        )
        await harness.waitUntilStarted()
        await harness.resume()
        await store.testWaitForBootstrapForTesting()
        #expect(store.acceptsDOMBundle(documentScopeID: store.currentDocumentScopeID) == true)
    }

    @Test
    func restartSelectionDependentRequestsAfterResyncDrainsDeferredFrontendRequests() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var dispatchedKinds: [String] = []
        store.testSetReady(true)
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if let kind = body["kind"] as? String {
                dispatchedKinds.append(kind)
            }
            return true
        }

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )
        #expect(didAdopt == true)

        store.handleRejectedDocumentRequestMessage(
            pageEpoch: store.currentPageEpoch,
            documentScopeID: store.currentDocumentScopeID
        )
        store.handleRejectedChildNodeRequestMessage(
            nodeID: 11,
            pageEpoch: store.currentPageEpoch,
            documentScopeID: store.currentDocumentScopeID
        )

        let didReject = await waitForCondition {
            dispatchedKinds.contains("rejectDocumentRequest")
                && dispatchedKinds.contains("rejectChildNodeRequest")
        }
        #expect(didReject == true)

        await store.clearDocumentReplacementAfterContextAdoptionRequirement()
        store.restartSelectionDependentRequestsAfterResync()

        let didDrain = await waitForCondition {
            dispatchedKinds.contains("completeDocumentRequest")
                && dispatchedKinds.contains("retryQueuedChildNodeRequests")
        }
        #expect(didDrain == true)
    }

    @Test
    func replacementSnapshotAfterContextAdoptionInvalidatesPriorNodeIdentity() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        replaceDocument(in: store, root: makeNode(localID: 42), selectedLocalID: 42)
        let initialSelectedNodeID = try! #require(store.currentDocumentModel.selectedNode?.id)
        let initialDocumentIdentity = store.currentDocumentModel.documentIdentity

        let didAdopt = await store.adoptPageContextIfNeeded(
            .init(pageEpoch: 4, documentScopeID: 6),
            preserveCurrentDocumentState: true
        )

        #expect(didAdopt == true)
        #expect(store.currentDocumentModel.documentIdentity == initialDocumentIdentity)
        #expect(store.currentDocumentModel.node(id: initialSelectedNodeID) != nil)

        let didApplyReplacement = await store.applyReplacementDOMBundleAfterContextAdoption(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "documentUpdated",
                    "snapshot": [
                        "root": [
                            "nodeId": 42,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": [],
                            "children": [],
                        ],
                        "selectedNodeId": 42,
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: store.currentDocumentScopeID
            )
        )

        #expect(didApplyReplacement == true)
        #expect(store.currentDocumentModel.documentIdentity != initialDocumentIdentity)
        #expect(store.currentDocumentModel.node(id: initialSelectedNodeID) == nil)
        #expect(store.currentDocumentModel.selectedNode?.id.localID == 42)
        #expect(store.currentDocumentModel.selectedNode?.id != initialSelectedNodeID)
    }

    @Test
    func freshRequestDocumentDoesNotCommitProjectedScopeWhenDocumentScopeSyncFails() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testFrontendDispatchOverride = { _ in true }
        store.testDocumentScopeSyncOverride = { _ in }
        store.testDocumentScopeSyncResultOverride = false
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        let initialScopeID = store.currentDocumentScopeID
        let initialDocumentIdentity = store.currentDocumentModel.documentIdentity

        let didRequestDocument = await store.requestDocument(depth: 4, mode: .fresh)

        #expect(didRequestDocument == false)
        #expect(store.currentDocumentScopeID == initialScopeID)
        #expect(store.currentDocumentModel.documentIdentity == initialDocumentIdentity)
        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 42)
    }

    @Test
    func freshRequestDocumentBoundsScopeSyncRetriesWhenPageIsAttached() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let webView = WKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        _ = await store.session.attach(to: webView)
        store.testSkipFreshRequestDocumentScopeSyncStub = true
        store.testFrontendDispatchOverride = { _ in true }
        store.testDocumentScopeSyncResultOverride = false
        store.testDocumentScopeResyncRetryAttemptsOverride = 3
        store.testDocumentScopeResyncRetryDelayNanosecondsOverride = 0
        var syncInvocationCount = 0
        store.testDocumentScopeSyncOverride = { _ in
            syncInvocationCount += 1
        }

        let didRequestDocument = await store.requestDocument(depth: 4, mode: .fresh)

        #expect(didRequestDocument == false)
        #expect(syncInvocationCount == 3)
    }

    @Test
    func currentDocumentScopeResyncReusesInFlightTask() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let syncHarness = BootstrapHarness()
        var syncInvocationCount = 0
        store.testDocumentScopeSyncOverride = { _ in
            syncInvocationCount += 1
            await syncHarness.blockUntilResumed()
        }

        let firstTask = Task {
            await store.testSyncCurrentDocumentScopeIDIfNeeded()
        }
        await syncHarness.waitUntilStarted()

        let secondTask = Task {
            await store.testSyncCurrentDocumentScopeIDIfNeeded()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(syncInvocationCount == 1)

        await syncHarness.resume()

        #expect(await firstTask.value == true)
        #expect(await secondTask.value == true)
        #expect(syncInvocationCount == 1)
    }

    @Test
    func currentDocumentScopeResyncDoesNotReuseCompletedTask() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var syncInvocationCount = 0
        store.testDocumentScopeSyncOverride = { _ in
            syncInvocationCount += 1
        }

        #expect(await store.testSyncCurrentDocumentScopeIDIfNeeded() == true)
        #expect(await store.testSyncCurrentDocumentScopeIDIfNeeded() == true)
        #expect(syncInvocationCount == 2)
    }

    @Test
    func mutationContextSyncFailsFastWithoutPageWebView() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var syncInvocationCount = 0
        store.testDocumentScopeSyncOverride = { _ in
            syncInvocationCount += 1
        }

        let didSync = await store.syncMutationContextToPageIfNeeded(store.currentMutationContext)

        #expect(didSync == false)
        #expect(syncInvocationCount == 0)
    }

    @Test
    func freshRequestDocumentAbortAfterScopeSyncResetsProjectedDocumentIdentity() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let syncHarness = BootstrapHarness()
        var syncedScopeID: UInt64?
        store.testFrontendDispatchOverride = { _ in true }
        store.testDocumentScopeSyncOverride = { scopeID in
            syncedScopeID = scopeID
            await syncHarness.blockUntilResumed()
        }
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )
        let initialScopeID = store.currentDocumentScopeID
        let initialSelectedNodeID = try! #require(store.currentDocumentModel.selectedNode?.id)
        let initialDocumentIdentity = store.currentDocumentModel.documentIdentity

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .fresh)
        }
        await syncHarness.waitUntilStarted()

        #expect(store.currentDocumentScopeID == initialScopeID)
        store.testSetPhaseIdleForCurrentPage()

        await syncHarness.resume()
        _ = await requestTask.value

        #expect(store.currentDocumentScopeID == syncedScopeID)
        #expect(store.currentDocumentModel.documentIdentity != initialDocumentIdentity)
        #expect(store.currentDocumentModel.selectedNode == nil)
        #expect(store.currentDocumentModel.node(id: initialSelectedNodeID) == nil)
    }

    @Test
    func freshRequestDocumentAbortAfterScopeSyncPreservesDeferredBootstrapDOMBundles() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let syncHarness = BootstrapHarness()
        let initialScopeID = store.currentDocumentScopeID
        var syncedScopeID: UInt64?
        var didStartConfigurationPass = false
        var allowConfigurationPassToFinish = false
        var flushedBundles: [Any] = []

        replaceDocument(in: store, root: makeNode(localID: 1))

        store.testSetReady(true)
        store.testConfigurationApplyOverride = { _ in
            didStartConfigurationPass = true
            while allowConfigurationPassToFinish == false, Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        store.testFrontendDispatchOverride = { _ in true }
        store.testDocumentScopeSyncOverride = { scopeID in
            syncedScopeID = scopeID
            await syncHarness.blockUntilResumed()
        }
        store.testMutationFlushOverride = { bundles in
            flushedBundles.append(contentsOf: bundles)
        }

        let bootstrapTask = Task {
            await store.updateConfiguration(
                .init(snapshotDepth: 8, subtreeDepth: 6, autoUpdateDebounce: 0.4)
            )
        }

        let didStartBootstrap = await waitForCondition {
            didStartConfigurationPass
        }
        #expect(didStartBootstrap == true)
        store.domDidEmit(
            bundle: .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.childNodeInserted",
                            "params": [
                                "parentNodeId": 1,
                                "previousNodeId": 0,
                                "node": [
                                    "nodeId": 2,
                                    "nodeType": 1,
                                    "nodeName": "SPAN",
                                    "localName": "span",
                                    "attributes": [],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .fresh)
        }
        await syncHarness.waitUntilStarted()

        store.testSetPhaseIdleForCurrentPage()

        await syncHarness.resume()
        _ = await requestTask.value

        allowConfigurationPassToFinish = true
        await bootstrapTask.value

        store.testSetReady(true)
        await store.testWaitForBootstrapForTesting()
        let didFlushDeferredBundle = await waitForCondition {
            flushedBundles.count == 1
        }

        #expect(store.currentDocumentScopeID == syncedScopeID)
        #expect(store.currentDocumentModel.rootNode == nil)
        #expect(store.currentDocumentModel.selectedNode == nil)
        #expect(didFlushDeferredBundle == true)
    }

    @Test
    func childNodeRequestFailureCompletesFrontendRequest() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var completionPayloads: [[String: Any]] = []
        store.testFrontendDispatchOverride = { payload in
            let body = (payload as? [String: Any]) ?? [:]
            if body["kind"] as? String == "completeChildNodeRequest" {
                completionPayloads.append(body)
            }
            return true
        }

        store.handleChildNodeRequestMessage([
            "nodeId": 11,
            "depth": 2,
        ])

        let didComplete = await waitForCondition {
            completionPayloads.contains {
                ($0["kind"] as? String) == "completeChildNodeRequest"
                    && ($0["nodeId"] as? Int) == 11
            }
        }
        #expect(didComplete == true)
    }

    @Test
    func resetInspectorStateClearsPendingBootstrapWork() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        var documentRequests: [(depth: Int, mode: DOMDocumentReloadMode)] = []
        store.testDocumentRequestApplyOverride = { depth, mode in
            documentRequests.append((depth, mode))
        }

        await store.setPreferredDepth(9)
        await store.requestDocument(depth: 9, mode: .fresh)
        store.testResetInspectorStateForTesting()
        store.testSetReady(true)
        await store.testWaitForBootstrapForTesting()

        #expect(documentRequests.isEmpty)
    }


    @Test
    func structuralMutationRestartsSelectorPathFetchForCurrentSelection() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        let tokenBefore = store.testSelectorPathRequestToken
        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "mutation",
                    "events": [
                        [
                            "method": "DOM.childNodeRemoved",
                            "params": [
                                "parentNodeId": 1,
                                "nodeId": 2,
                            ],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )

        #expect(store.testSelectorPathRequestToken > tokenBefore)
    }

    @Test
    func selectionUpdateAcceptsNSNumberAndDictionaryPayloads() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        let nsDictionaryPayload: NSDictionary = [
            "id": NSNumber(value: 77),
            "preview": "<div id=\"target\">",
            "attributes": [
                [
                    "name": "id",
                    "value": "target",
                ],
            ],
            "path": ["html", "body", "div"],
            "selectorPath": "div#target",
            "styleRevision": NSNumber(value: 2),
        ]
        store.testHandleDOMSelectionMessage(nsDictionaryPayload)

        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 77)
        #expect(store.currentDocumentModel.selectedNode?.selectorPath == "div#target")
        #expect(store.currentDocumentModel.selectedNode?.styleRevision == 2)

        let swiftDictionaryPayload: [String: Any] = [
            "id": 78,
            "preview": "<div id=\"swift-target\">",
            "attributes": [
                [
                    "name": "id",
                    "value": "swift-target",
                ],
            ],
            "path": ["html", "body", "div"],
            "selectorPath": "div#swift-target",
            "styleRevision": 3,
        ]
        store.testHandleDOMSelectionMessage(swiftDictionaryPayload)

        #expect(store.currentDocumentModel.selectedNode?.backendNodeID == 78)
        #expect(store.currentDocumentModel.selectedNode?.selectorPath == "div#swift-target")
        #expect(store.currentDocumentModel.selectedNode?.styleRevision == 3)
    }

    @Test
    func selectionUpdateWithoutSelectorPathPreservesExistingSelectorPath() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div id=\"target\">",
            "attributes": [["name": "id", "value": "target"]],
            "path": ["html", "body", "div"],
            "styleRevision": 1,
        ])

        #expect(store.currentDocumentModel.selectedNode?.selectorPath == "div#target")
    }

    @Test
    func selectorPathLookupFailureClearsExistingSelectorPath() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        seedSelection(
            store,
            localID: 42,
            preview: "<div id=\"target\">",
            attributes: [.init(nodeId: 42, name: "id", value: "target")],
            path: ["html", "body", "div"],
            selectorPath: "div#target",
            styleRevision: 1,
            matchedStyles: [],
            isLoading: false
        )

        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div id=\"target\">",
            "attributes": [["name": "id", "value": "target"]],
            "path": ["html", "body", "div"],
            "styleRevision": 2,
        ])

        let didClear = await waitForCondition {
            store.currentDocumentModel.selectedNode?.selectorPath == ""
        }
        #expect(didClear == true)
    }







    private func makeStore(autoUpdateDebounce: TimeInterval) -> DOMInspectorRuntime {
        let session = DOMSession(
            configuration: .init(
                snapshotDepth: 4,
                subtreeDepth: 3,
                autoUpdateDebounce: autoUpdateDebounce
            )
        )
        return DOMInspectorRuntime(session: session)
    }

    private func drainInitialBootstrapWork(_ store: DOMInspectorRuntime) async {
        store.testSetReady(true)
        await store.testWaitForBootstrapForTesting()
        store.testSetReady(false)
    }

    private func replaceDocument(
        in store: DOMInspectorRuntime,
        root: DOMGraphNodeDescriptor,
        selectedLocalID: UInt64? = nil
    ) {
        store.currentDocumentModel.replaceDocument(
            with: .init(root: root, selectedLocalID: selectedLocalID)
        )
    }

    private func makeNode(
        localID: UInt64,
        nodeType: Int = 1,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = "",
        attributes: [DOMAttribute] = [],
        childCount: Int? = nil,
        layoutFlags: [String] = [],
        isRendered: Bool = true,
        children: [DOMGraphNodeDescriptor] = []
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: localID <= UInt64(Int.max) ? Int(localID) : nil,
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: childCount ?? children.count,
            layoutFlags: layoutFlags,
            isRendered: isRendered,
            children: children
        )
    }

    private func seedSelection(
        _ store: DOMInspectorRuntime,
        localID: UInt64,
        preview: String,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String,
        styleRevision: Int,
        matchedStyles _: [DOMMatchedStyleRule],
        isLoading _: Bool
    ) {
        store.currentDocumentModel.applySelectionSnapshot(
            .init(
                localID: localID,
                preview: preview,
                attributes: attributes,
                path: path,
                selectorPath: selectorPath,
                styleRevision: styleRevision
            )
        )
    }

    private func rootLocalID(from delta: DOMGraphDelta?) -> UInt64? {
        guard case let .snapshot(snapshot, _) = delta else {
            return nil
        }
        return snapshot.root.localID
    }

    private func anonymousNodePayload() -> [String: Any] {
        [
            "nodeType": 1,
            "nodeName": "DIV",
            "localName": "div",
            "nodeValue": "",
            "attributes": [],
            "children": [],
        ]
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func waitForCondition(
        maxAttempts: Int = 100,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxAttempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    private func summary(for configuration: DOMConfiguration) -> DOMConfigurationSummary {
        .init(
            snapshotDepth: configuration.snapshotDepth,
            subtreeDepth: configuration.subtreeDepth,
            autoUpdateDebounce: configuration.autoUpdateDebounce
        )
    }
}

private struct DOMConfigurationSummary: Equatable {
    let snapshotDepth: Int
    let subtreeDepth: Int
    let autoUpdateDebounce: TimeInterval
}

private enum ReconcileEvent: Equatable {
    case configuration(DOMConfigurationSummary)
    case preferredDepth(Int)
}

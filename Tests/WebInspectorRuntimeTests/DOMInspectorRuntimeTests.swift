import Foundation
import Testing
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
        await withCheckedContinuation { continuation in
            if resumed {
                continuation.resume()
                return
            }
            resumeContinuation = continuation
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

        store.currentDocumentStore.replaceDocument(
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

        #expect(store.currentDocumentStore.rootEntry?.children.first == nil)

        await harness.resume()
        await bootstrapTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(store.currentDocumentStore.rootEntry?.children.first?.backendNodeID == 2)
    }

    @Test
    func domBundlesQueuedDuringDocumentBootstrapApplyAfterSnapshotReplacement() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()

        store.currentDocumentStore.replaceDocument(
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
            store.currentDocumentStore.replaceDocument(
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

        #expect(store.currentDocumentStore.rootEntry?.attributes.first?.value == "before")

        await harness.resume()
        await requestTask.value
        await store.testWaitForBootstrapForTesting()

        #expect(store.currentDocumentStore.rootEntry?.attributes.first?.value == "mutation")
    }

    @Test
    func deferredBootstrapReplayContinuesAfterDocumentUpdatedBoundary() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = BootstrapHarness()

        store.currentDocumentStore.replaceDocument(
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

        #expect(store.currentDocumentStore.rootEntry?.backendNodeID == 7)
        #expect(store.currentDocumentStore.rootEntry?.attributes.first?.value == "after")
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
        #expect(store.currentDocumentStore.rootEntry?.backendNodeID == 1)
        #expect(store.currentDocumentStore.selectedEntry == nil)
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
        store.currentDocumentStore.setErrorMessage("stale")

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

        #expect(store.currentDocumentStore.rootEntry?.backendNodeID == 1)
        #expect(store.currentDocumentStore.selectedEntry == nil)
        #expect(store.currentDocumentStore.errorMessage == nil)
    }

    @Test
    func resetMarkedSnapshotInvalidatesInFlightMatchedStylesForReusedSelectionID() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = MatchedStylesFetcherHarness()
        store.testMatchedStylesFetcher = { nodeID in
            try await harness.fetch(nodeID: nodeID)
        }

        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 1))
        let initialRequestIDs = await waitForPendingMatchedStylesRequestIDs(count: 1, harness: harness)
        guard let firstRequestID = initialRequestIDs.first else {
            Issue.record("Expected first matched styles request to be pending")
            return
        }

        store.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "snapshot": [
                        "root": [
                            "nodeId": 42,
                            "nodeType": 1,
                            "nodeName": "DIV",
                            "localName": "div",
                            "attributes": [],
                            "children": [],
                        ],
                    ],
                ],
                pageEpoch: store.currentPageEpoch
            )
        )
        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 2))

        let restartedRequestIDs = await waitForPendingMatchedStylesRequestIDs(count: 2, harness: harness)
        guard restartedRequestIDs.count >= 2 else {
            Issue.record("Expected restarted matched styles request to be pending")
            return
        }
        let secondRequestID = restartedRequestIDs[1]

        #expect(harness.resolve(firstRequestID, selectorText: ".stale") == true)

        let staleDidNotApply = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.matchedStyles.isEmpty == true
                && store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == true
        }
        #expect(staleDidNotApply == true)

        #expect(harness.resolve(secondRequestID, selectorText: ".fresh") == true)

        let appliedFresh = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.matchedStyles == [matchedStylesRule(selectorText: ".fresh")]
                && store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == false
        }
        #expect(appliedFresh == true)
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

        #expect(store.currentDocumentStore.selectedEntry == nil)
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

        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preservingInspectorState: true)
        let flushDidStart = await waitForCondition {
            store.testHasActiveBundleFlushTask
        }
        #expect(flushDidStart == true)

        let requestTask = Task {
            await store.requestDocument(depth: 4, mode: .fresh)
        }

        await harness.waitUntilStarted()
        #expect(store.currentDocumentStore.selectedEntry != nil)

        await harness.resume()
        await requestTask.value

        #expect(store.currentDocumentStore.selectedEntry == nil)
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
        #expect(store.currentDocumentStore.selectedEntry == nil)
        #expect(store.testCompletedMutationGeneration == 0)
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

        #expect(store.currentDocumentStore.selectedEntry == nil)
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

        await store.requestDocument(depth: 4, mode: .fresh)

        #expect(dispatchedKinds == ["resetChildNodeRequests"])
        #expect(store.currentDocumentStore.selectedEntry?.backendNodeID == 42)
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
    func selectionUpdateWithSameNodeDoesNotRestartMatchedStylesFetch() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let existingRule = DOMMatchedStyleRule(
            origin: .author,
            selectorText: ".same-node",
            declarations: [
                .init(name: "color", value: "red", important: false)
            ],
            sourceLabel: "<style>"
        )

        seedSelection(
            store,
            localID: 42,
            preview: "<div class=\"same-node\">",
            attributes: [.init(nodeId: 42, name: "class", value: "same-node")],
            path: ["html", "body", "div"],
            selectorPath: "div.same-node",
            styleRevision: 1,
            matchedStyles: [existingRule],
            isLoading: false
        )

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node\">",
            "attributes": [["name": "class", "value": "same-node"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node",
            "styleRevision": 1,
        ])

        #expect(store.testMatchedStylesRequestToken == tokenBefore)
        #expect(store.currentDocumentStore.selectedEntry?.matchedStyles == [existingRule])
        #expect(store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == false)
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
        let tokenBefore = store.testMatchedStylesRequestToken

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

        #expect(store.currentDocumentStore.selectedEntry?.backendNodeID == 77)
        #expect(store.currentDocumentStore.selectedEntry?.selectorPath == "div#target")
        #expect(store.currentDocumentStore.selectedEntry?.styleRevision == 2)
        #expect(store.testMatchedStylesRequestToken > tokenBefore)

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

        #expect(store.currentDocumentStore.selectedEntry?.backendNodeID == 78)
        #expect(store.currentDocumentStore.selectedEntry?.selectorPath == "div#swift-target")
        #expect(store.currentDocumentStore.selectedEntry?.styleRevision == 3)
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

        #expect(store.currentDocumentStore.selectedEntry?.selectorPath == "div#target")
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
            store.currentDocumentStore.selectedEntry?.selectorPath == ""
        }
        #expect(didClear == true)
    }

    @Test
    func selectionUpdateWithSameNodeAndChangedAttributesRestartsMatchedStylesFetch() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let existingRule = DOMMatchedStyleRule(
            origin: .author,
            selectorText: ".same-node",
            declarations: [
                .init(name: "color", value: "red", important: false)
            ],
            sourceLabel: "<style>"
        )

        seedSelection(
            store,
            localID: 42,
            preview: "<div class=\"same-node\">",
            attributes: [.init(nodeId: 42, name: "class", value: "same-node")],
            path: ["html", "body", "div"],
            selectorPath: "div.same-node",
            styleRevision: 1,
            matchedStyles: [existingRule],
            isLoading: false
        )

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node changed\">",
            "attributes": [["name": "class", "value": "same-node changed"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node.changed",
            "styleRevision": 1,
        ])

        #expect(store.testMatchedStylesRequestToken > tokenBefore)
        #expect(store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == true)
        #expect(store.currentDocumentStore.selectedEntry?.matchedStyles.isEmpty == true)
    }

    @Test
    func selectionUpdateWithSameNodeAndChangedAttributesWhileLoadingRestartsMatchedStylesFetch() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let existingRule = DOMMatchedStyleRule(
            origin: .author,
            selectorText: ".same-node",
            declarations: [
                .init(name: "color", value: "red", important: false)
            ],
            sourceLabel: "<style>"
        )

        seedSelection(
            store,
            localID: 42,
            preview: "<div class=\"same-node\">",
            attributes: [.init(nodeId: 42, name: "class", value: "same-node")],
            path: ["html", "body", "div"],
            selectorPath: "div.same-node",
            styleRevision: 1,
            matchedStyles: [existingRule],
            isLoading: true
        )

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node changed\">",
            "attributes": [["name": "class", "value": "same-node changed"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node.changed",
            "styleRevision": 1,
        ])

        #expect(store.testMatchedStylesRequestToken > tokenBefore)
        #expect(store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == true)
        #expect(store.currentDocumentStore.selectedEntry?.matchedStyles.isEmpty == true)
    }

    @Test
    func selectionUpdateWithSameNodeAndChangedStyleRevisionRestartsMatchedStylesFetch() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let existingRule = DOMMatchedStyleRule(
            origin: .author,
            selectorText: ".same-node",
            declarations: [
                .init(name: "color", value: "red", important: false)
            ],
            sourceLabel: "<style>"
        )

        seedSelection(
            store,
            localID: 42,
            preview: "<div class=\"same-node\">",
            attributes: [.init(nodeId: 42, name: "class", value: "same-node")],
            path: ["html", "body", "div"],
            selectorPath: "div.same-node",
            styleRevision: 1,
            matchedStyles: [existingRule],
            isLoading: false
        )

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node\">",
            "attributes": [["name": "class", "value": "same-node"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node",
            "styleRevision": 2,
        ])

        #expect(store.testMatchedStylesRequestToken > tokenBefore)
        #expect(store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == true)
        #expect(store.currentDocumentStore.selectedEntry?.matchedStyles.isEmpty == true)
    }

    @Test
    func cancelledMatchedStylesSuccessDoesNotOverwriteNewerResult() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = MatchedStylesFetcherHarness()
        store.testMatchedStylesFetcher = { nodeID in
            try await harness.fetch(nodeID: nodeID)
        }

        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 1))
        let initialRequestIDs = await waitForPendingMatchedStylesRequestIDs(count: 1, harness: harness)
        guard let firstRequestID = initialRequestIDs.first else {
            Issue.record("Expected first matched styles request to be pending")
            return
        }

        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 2))
        let restartedRequestIDs = await waitForPendingMatchedStylesRequestIDs(count: 2, harness: harness)
        guard restartedRequestIDs.count >= 2 else {
            Issue.record("Expected restarted matched styles request to be pending")
            return
        }
        let secondRequestID = restartedRequestIDs[1]

        #expect(firstRequestID != secondRequestID)
        #expect(harness.resolve(secondRequestID, selectorText: ".latest") == true)

        let appliedLatest = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.matchedStyles == [matchedStylesRule(selectorText: ".latest")]
                && store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == false
        }
        #expect(appliedLatest == true)

        #expect(harness.resolve(firstRequestID, selectorText: ".stale") == true)

        let staleDidNotOverwrite = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.matchedStyles == [matchedStylesRule(selectorText: ".latest")]
                && store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == false
        }
        #expect(staleDidNotOverwrite == true)
    }

    @Test
    func cancelledMatchedStylesFailureDoesNotClearNewerLoadingStateOrResult() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = MatchedStylesFetcherHarness()
        store.testMatchedStylesFetcher = { nodeID in
            try await harness.fetch(nodeID: nodeID)
        }

        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 1))
        let initialRequestIDs = await waitForPendingMatchedStylesRequestIDs(count: 1, harness: harness)
        guard let firstRequestID = initialRequestIDs.first else {
            Issue.record("Expected first matched styles request to be pending")
            return
        }

        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 2))
        let restartedRequestIDs = await waitForPendingMatchedStylesRequestIDs(count: 2, harness: harness)
        guard restartedRequestIDs.count >= 2 else {
            Issue.record("Expected restarted matched styles request to be pending")
            return
        }
        let secondRequestID = restartedRequestIDs[1]

        let restartedLoading = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == true
        }
        #expect(restartedLoading == true)

        #expect(harness.reject(firstRequestID, message: "cancelled stale request") == true)

        let staleFailureDidNotClearLoading = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == true
                && store.currentDocumentStore.selectedEntry?.matchedStyles.isEmpty == true
        }
        #expect(staleFailureDidNotClearLoading == true)

        #expect(harness.resolve(secondRequestID, selectorText: ".latest") == true)

        let appliedLatest = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.matchedStyles == [matchedStylesRule(selectorText: ".latest")]
                && store.currentDocumentStore.selectedEntry?.isLoadingMatchedStyles == false
        }
        #expect(appliedLatest == true)
    }

    @Test
    func matchedStylesLookupAppliesToRebuiltSelectedEntryWithSameBackendNodeID() async {
        let store = makeStore(autoUpdateDebounce: 0.4)
        let harness = MatchedStylesFetcherHarness()
        store.testMatchedStylesFetcher = { nodeID in
            try await harness.fetch(nodeID: nodeID)
        }

        replaceDocument(
            in: store,
            root: makeNode(localID: 1, children: [makeNode(localID: 42)]),
            selectedLocalID: 42
        )

        store.testHandleDOMSelectionMessage(matchedStylesSelectionPayload(styleRevision: 1))
        let requestIDs = await waitForPendingMatchedStylesRequestIDs(count: 1, harness: harness)
        guard let requestID = requestIDs.first else {
            Issue.record("Expected matched styles request to be pending")
            return
        }

        let originalSelection = store.currentDocumentStore.selectedEntry
        replaceDocument(
            in: store,
            root: makeNode(
                localID: 1,
                children: [
                    makeNode(localID: 42, attributes: [.init(name: "id", value: "target")]),
                ]
            ),
            selectedLocalID: 42
        )

        #expect(store.currentDocumentStore.selectedEntry !== originalSelection)
        #expect(harness.resolve(requestID, selectorText: ".rebuilt") == true)

        let appliedToRebuiltSelection = await waitForCondition {
            store.currentDocumentStore.selectedEntry?.matchedStyles == [matchedStylesRule(selectorText: ".rebuilt")]
                && store.currentDocumentStore.selectedEntry !== originalSelection
        }
        #expect(appliedToRebuiltSelection == true)
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

    private func waitForPendingMatchedStylesRequestIDs(
        count: Int,
        harness: MatchedStylesFetcherHarness
    ) async -> [Int] {
        var latestIDs: [Int] = []
        for _ in 0..<100 {
            latestIDs = harness.pendingRequestIDs
            if latestIDs.count >= count {
                return latestIDs
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return latestIDs
    }

    private func matchedStylesSelectionPayload(styleRevision: Int) -> [String: Any] {
        [
            "id": 42,
            "preview": "<div id=\"target\">",
            "attributes": [["name": "id", "value": "target"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div#target",
            "styleRevision": styleRevision,
        ]
    }

    private func matchedStylesRule(selectorText: String) -> DOMMatchedStyleRule {
        DOMMatchedStyleRule(
            origin: .author,
            selectorText: selectorText,
            declarations: [
                .init(name: "color", value: selectorText, important: false)
            ],
            sourceLabel: "<style>"
        )
    }

    private func replaceDocument(
        in store: DOMInspectorRuntime,
        root: DOMGraphNodeDescriptor,
        selectedLocalID: UInt64? = nil
    ) {
        store.currentDocumentStore.replaceDocument(
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
        matchedStyles: [DOMMatchedStyleRule],
        isLoading: Bool
    ) {
        store.currentDocumentStore.applySelectionSnapshot(
            .init(
                localID: localID,
                preview: preview,
                attributes: attributes,
                path: path,
                selectorPath: selectorPath,
                styleRevision: styleRevision
            )
        )
        if !matchedStyles.isEmpty {
            if let selectedEntry = store.currentDocumentStore.selectedEntry {
                store.currentDocumentStore.applyMatchedStyles(
                    .init(
                        nodeId: Int(localID),
                        rules: matchedStyles,
                        truncated: false,
                        blockedStylesheetCount: 0
                    ),
                    for: selectedEntry
                )
            }
        }
        if isLoading {
            if let selectedEntry = store.currentDocumentStore.selectedEntry {
                store.currentDocumentStore.beginMatchedStylesLoading(for: selectedEntry)
            }
        }
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

@MainActor
private final class MatchedStylesFetcherHarness {
    private var nextRequestID = 0
    private var pendingByID: [Int: PendingRequest] = [:]
    private var pendingOrder: [Int] = []

    var pendingRequestIDs: [Int] {
        pendingOrder.filter { pendingByID[$0] != nil }
    }

    func fetch(nodeID: Int) async throws -> DOMMatchedStylesPayload {
        try await withCheckedThrowingContinuation { continuation in
            nextRequestID += 1
            let requestID = nextRequestID
            pendingByID[requestID] = PendingRequest(
                nodeID: nodeID,
                continuation: continuation
            )
            pendingOrder.append(requestID)
        }
    }

    func resolve(_ requestID: Int, selectorText: String) -> Bool {
        guard let pending = takePendingRequest(id: requestID) else {
            return false
        }
        pending.continuation.resume(
            returning: DOMMatchedStylesPayload(
                nodeId: pending.nodeID,
                rules: [
                    DOMMatchedStyleRule(
                        origin: .author,
                        selectorText: selectorText,
                        declarations: [
                            .init(name: "color", value: selectorText, important: false)
                        ],
                        sourceLabel: "<style>"
                    )
                ],
                truncated: false,
                blockedStylesheetCount: 0
            )
        )
        return true
    }

    func reject(_ requestID: Int, message: String) -> Bool {
        guard let pending = takePendingRequest(id: requestID) else {
            return false
        }
        pending.continuation.resume(
            throwing: NSError(
                domain: "MatchedStylesFetcherHarness",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
        return true
    }

    private func takePendingRequest(id requestID: Int) -> PendingRequest? {
        pendingOrder.removeAll { $0 == requestID }
        return pendingByID.removeValue(forKey: requestID)
    }

    private struct PendingRequest {
        let nodeID: Int
        let continuation: CheckedContinuation<DOMMatchedStylesPayload, Error>
    }
}

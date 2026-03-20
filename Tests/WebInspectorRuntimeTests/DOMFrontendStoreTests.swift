import Foundation
import Testing
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
struct DOMFrontendStoreTests {
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
    func payloadNormalizerResetsFallbackLocalIDBeforeProtocolGetDocumentNormalization() {
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
        guard case let .snapshot(snapshot, resetDocument)? = normalizer.normalizeProtocolResponse(
            method: "DOM.getDocument",
            responseObject: responseObject,
            resetDocument: true
        ) else {
            Issue.record("Failed to normalize protocol DOM.getDocument response")
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
        let store = makeStore(autoUpdateDebounce: 0.4)
        let snapshotPayload: [String: Any] = [
            "version": 1,
            "kind": "snapshot",
            "snapshot": [
                "root": anonymousNodePayload(),
            ],
        ]

        store.domDidEmit(bundle: .init(objectEnvelope: snapshotPayload))
        let firstRootID = store.session.graphStore.rootID?.localID
        store.domDidEmit(bundle: .init(objectEnvelope: snapshotPayload))
        let secondRootID = store.session.graphStore.rootID?.localID

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
        store.domDidEmit(bundle: .init(objectEnvelope: mutationPayload))
        store.domDidEmit(bundle: .init(objectEnvelope: snapshotPayload))
        let rootIDAfterDocumentUpdate = store.session.graphStore.rootID?.localID

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
    func payloadNormalizerParsesStringResultForRequestChildNodesResponse() {
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

        guard case let .replaceSubtree(node) = normalizer.normalizeProtocolResponse(
            method: "DOM.requestChildNodes",
            responseObject: responseObject,
            resetDocument: false
        ) else {
            Issue.record("Failed to normalize string result for DOM.requestChildNodes")
            return
        }

        #expect(node.localID == 123)
        #expect(node.nodeName == "DIV")
    }

    @Test
    func protocolRequestWantsDocumentResetTreatsMissingPreserveStateAsReset() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        #expect(
            store.testProtocolRequestWantsDocumentReset(
                method: "DOM.getDocument",
                payload: [
                    "method": "DOM.getDocument",
                ]
            ) == true
        )
        #expect(
            store.testProtocolRequestWantsDocumentReset(
                method: "DOM.getDocument",
                payload: [
                    "method": "DOM.getDocument",
                    "params": [
                        "preserveState": true,
                    ],
                ]
            ) == false
        )
        #expect(
            store.testProtocolRequestWantsDocumentReset(
                method: "DOM.getDocument",
                payload: [
                    "method": "DOM.getDocument",
                    "params": [
                        "preserveState": false,
                    ],
                ]
            ) == true
        )
        #expect(
            store.testProtocolRequestWantsDocumentReset(
                method: "DOM.requestChildNodes",
                payload: [
                    "method": "DOM.requestChildNodes",
                ]
            ) == false
        )
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
    func enqueueMutationBundleWhileNotReadyDoesNotScheduleFlush() {
        let store = makeStore(autoUpdateDebounce: 0.4)

        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preserveState: true)

        #expect(store.pendingMutationBundleCount == 1)
        #expect(store.testHasPendingBundleFlushTask == false)
    }

    @Test
    func clearPendingMutationBundlesCancelsScheduledFlushWhenReady() {
        let store = makeStore(autoUpdateDebounce: 0.4)
        store.testSetReady(true)

        store.enqueueMutationBundle("{\"kind\":\"mutation\"}", preserveState: true)
        #expect(store.pendingMutationBundleCount == 1)
        #expect(store.testHasPendingBundleFlushTask == true)

        store.clearPendingMutationBundles()
        #expect(store.pendingMutationBundleCount == 0)
        #expect(store.testHasPendingBundleFlushTask == false)
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
        #expect(store.session.graphStore.selectedEntry?.matchedStyles == [existingRule])
        #expect(store.session.graphStore.selectedEntry?.isLoadingMatchedStyles == false)
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

        #expect(store.session.graphStore.selectedEntry?.backendNodeID == 77)
        #expect(store.session.graphStore.selectedEntry?.selectorPath == "div#target")
        #expect(store.session.graphStore.selectedEntry?.styleRevision == 2)
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

        #expect(store.session.graphStore.selectedEntry?.backendNodeID == 78)
        #expect(store.session.graphStore.selectedEntry?.selectorPath == "div#swift-target")
        #expect(store.session.graphStore.selectedEntry?.styleRevision == 3)
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
        #expect(store.session.graphStore.selectedEntry?.isLoadingMatchedStyles == true)
        #expect(store.session.graphStore.selectedEntry?.matchedStyles.isEmpty == true)
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
        #expect(store.session.graphStore.selectedEntry?.isLoadingMatchedStyles == true)
        #expect(store.session.graphStore.selectedEntry?.matchedStyles.isEmpty == true)
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
        #expect(store.session.graphStore.selectedEntry?.isLoadingMatchedStyles == true)
        #expect(store.session.graphStore.selectedEntry?.matchedStyles.isEmpty == true)
    }

    private func makeStore(autoUpdateDebounce: TimeInterval) -> DOMFrontendStore {
        let session = DOMSession(
            configuration: .init(
                snapshotDepth: 4,
                subtreeDepth: 3,
                autoUpdateDebounce: autoUpdateDebounce
            )
        )
        return DOMFrontendStore(session: session)
    }

    private func seedSelection(
        _ store: DOMFrontendStore,
        localID: UInt64,
        preview: String,
        attributes: [DOMAttribute],
        path: [String],
        selectorPath: String,
        styleRevision: Int,
        matchedStyles: [DOMMatchedStyleRule],
        isLoading: Bool
    ) {
        store.session.graphStore.applySelectionSnapshot(
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
            store.session.graphStore.applyMatchedStyles(
                .init(
                    nodeId: Int(localID),
                    rules: matchedStyles,
                    truncated: false,
                    blockedStylesheetCount: 0
                ),
                for: localID
            )
        }
        if isLoading {
            store.session.graphStore.beginMatchedStylesLoading(for: localID)
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
}

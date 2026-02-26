import Foundation
import Testing
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
struct DOMFrontendStoreTests {
    @Test
    func bundleFlushIntervalClampsToExpectedRange() {
        let store = makeStore(autoUpdateDebounce: 0.01)
        #expect(abs(store.testBundleFlushInterval - 0.05) < 0.0001)

        store.updateConfiguration(
            .init(snapshotDepth: 4, subtreeDepth: 3, autoUpdateDebounce: 0.4)
        )
        #expect(abs(store.testBundleFlushInterval - 0.1) < 0.0001)

        store.updateConfiguration(
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
        store.session.selection.nodeId = 42
        store.session.selection.preview = "<div class=\"same-node\">"
        store.session.selection.path = ["html", "body", "div"]
        store.session.selection.attributes = [
            .init(nodeId: 42, name: "class", value: "same-node"),
        ]
        store.session.selection.selectorPath = "div.same-node"
        store.session.selection.matchedStyles = [existingRule]
        store.session.selection.isLoadingMatchedStyles = false

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node\">",
            "attributes": [["name": "class", "value": "same-node"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node",
        ])

        #expect(store.testMatchedStylesRequestToken == tokenBefore)
        #expect(store.session.selection.matchedStyles == [existingRule])
        #expect(store.session.selection.isLoadingMatchedStyles == false)
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

        #expect(store.session.selection.nodeId == 77)
        #expect(store.session.selection.selectorPath == "div#target")
        #expect(store.session.selection.styleRevision == 2)
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

        #expect(store.session.selection.nodeId == 78)
        #expect(store.session.selection.selectorPath == "div#swift-target")
        #expect(store.session.selection.styleRevision == 3)
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
        store.session.selection.nodeId = 42
        store.session.selection.preview = "<div class=\"same-node\">"
        store.session.selection.path = ["html", "body", "div"]
        store.session.selection.attributes = [
            .init(nodeId: 42, name: "class", value: "same-node"),
        ]
        store.session.selection.matchedStyles = [existingRule]
        store.session.selection.isLoadingMatchedStyles = false

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node changed\">",
            "attributes": [["name": "class", "value": "same-node changed"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node.changed",
        ])

        #expect(store.testMatchedStylesRequestToken > tokenBefore)
        #expect(store.session.selection.isLoadingMatchedStyles == true)
        #expect(store.session.selection.matchedStyles.isEmpty)
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
        store.session.selection.nodeId = 42
        store.session.selection.preview = "<div class=\"same-node\">"
        store.session.selection.path = ["html", "body", "div"]
        store.session.selection.attributes = [
            .init(nodeId: 42, name: "class", value: "same-node"),
        ]
        store.session.selection.matchedStyles = [existingRule]
        store.session.selection.isLoadingMatchedStyles = true

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node changed\">",
            "attributes": [["name": "class", "value": "same-node changed"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node.changed",
        ])

        #expect(store.testMatchedStylesRequestToken > tokenBefore)
        #expect(store.session.selection.isLoadingMatchedStyles == true)
        #expect(store.session.selection.matchedStyles.isEmpty)
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
        store.session.selection.nodeId = 42
        store.session.selection.preview = "<div class=\"same-node\">"
        store.session.selection.path = ["html", "body", "div"]
        store.session.selection.attributes = [
            .init(nodeId: 42, name: "class", value: "same-node"),
        ]
        store.session.selection.styleRevision = 1
        store.session.selection.matchedStyles = [existingRule]
        store.session.selection.isLoadingMatchedStyles = false

        let tokenBefore = store.testMatchedStylesRequestToken
        store.testHandleDOMSelectionMessage([
            "id": 42,
            "preview": "<div class=\"same-node\">",
            "attributes": [["name": "class", "value": "same-node"]],
            "path": ["html", "body", "div"],
            "selectorPath": "div.same-node",
            "styleRevision": 2
        ])

        #expect(store.testMatchedStylesRequestToken > tokenBefore)
        #expect(store.session.selection.isLoadingMatchedStyles == true)
        #expect(store.session.selection.matchedStyles.isEmpty)
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
}

import Foundation
import Testing
@testable import WebInspectorUI
@testable import WebInspectorCore
@testable import WebInspectorNetwork

#if canImport(AppKit)
import AppKit

@MainActor


struct NetworkInspectorAppKitTests {
    @Test
    func networkTabDoesNotAutoSelectEntryWhenEntriesExist() throws {
        let inspector = WINetworkInspectorStore(session: NetworkSession())
        let queryModel = WINetworkQueryState(inspector: inspector)
        try applyRequestStart(
            to: inspector,
            requestID: 101,
            url: "https://example.com/first",
            initiator: "document",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: inspector,
            requestID: 102,
            url: "https://example.com/second",
            initiator: "script",
            monotonicMs: 1_010
        )

        let controller = WINetworkViewController(inspector: inspector, queryModel: queryModel)
        controller.loadViewIfNeeded()

        #expect(inspector.selectedEntry == nil)
    }

    @Test
    func networkTabUpdatesDetailWhenSelectionChanges() throws {
        let inspector = WINetworkInspectorStore(session: NetworkSession())
        let queryModel = WINetworkQueryState(inspector: inspector)
        try applyRequestStart(
            to: inspector,
            requestID: 111,
            url: "https://example.com/first",
            initiator: "document",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: inspector,
            requestID: 112,
            url: "https://example.com/second",
            initiator: "script",
            monotonicMs: 1_010
        )

        let controller = WINetworkViewController(inspector: inspector, queryModel: queryModel)
        controller.loadViewIfNeeded()
        let selected = try #require(
            queryModel.displayEntries.first(where: { $0.requestID == 112 })
        )

        inspector.selectEntry(selected)

        #expect(inspector.selectedEntry?.id == selected.id)
    }

    @Test
    func networkTabLifecycleCanRepeatWithoutLeaking() async throws {
        let inspector = WINetworkInspectorStore(session: NetworkSession())
        let queryModel = WINetworkQueryState(inspector: inspector)
        try applyRequestStart(
            to: inspector,
            requestID: 201,
            url: "https://example.com/resource.js",
            initiator: "script",
            monotonicMs: 1_000
        )

        var controller: WINetworkViewController? = WINetworkViewController(
            inspector: inspector,
            queryModel: queryModel
        )
        weak let weakController = controller
        controller?.loadViewIfNeeded()
        let lifecycleTask = Task { @MainActor in
            for _ in 0..<8 {
                controller?.viewWillAppear()
                controller?.viewDidDisappear()
            }
        }
        await lifecycleTask.value

        controller = nil
        #expect(weakController == nil)
    }

    private func applyRequestStart(
        to inspector: WINetworkInspectorStore,
        requestID: Int,
        url: String,
        initiator: String,
        monotonicMs: Double
    ) throws {
        let payload: [String: Any] = [
            "kind": "requestWillBeSent",
            "requestId": requestID,
            "url": url,
            "method": "GET",
            "initiator": initiator,
            "time": [
                "monotonicMs": monotonicMs,
                "wallMs": 1_700_000_000_000.0 + monotonicMs
            ]
        ]
        let event = try decodeEvent(payload)
        inspector.store.applyEvent(event)
    }

    private func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> HTTPNetworkEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(NetworkEventPayload.self, from: data)
        return try #require(HTTPNetworkEvent(payload: decoded, sessionID: sessionID))
    }
}
#endif

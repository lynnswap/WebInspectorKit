import Foundation
import Testing
import WebInspectorKit
@testable import WebInspectorUI
@testable import WebInspectorCore
@testable import WebInspectorCore

#if canImport(AppKit)
import AppKit

@MainActor

@Suite(.serialized, .webKitIsolated)
struct NetworkInspectorAppKitTests {
    @Test
    func networkTabDoesNotAutoSelectEntryWhenEntriesExist() throws {
        let store = WINetworkStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(store: store)
        try applyRequestStart(
            to: store,
            requestID: 101,
            url: "https://example.com/first",
            initiator: "document",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: store,
            requestID: 102,
            url: "https://example.com/second",
            initiator: "script",
            monotonicMs: 1_010
        )

        let controller = WINetworkViewController(store: store, queryModel: queryModel)
        controller.loadViewIfNeeded()

        #expect(store.selectedEntry == nil)
    }

    @Test
    func networkTabUpdatesDetailWhenSelectionChanges() throws {
        let store = WINetworkStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(store: store)
        try applyRequestStart(
            to: store,
            requestID: 111,
            url: "https://example.com/first",
            initiator: "document",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: store,
            requestID: 112,
            url: "https://example.com/second",
            initiator: "script",
            monotonicMs: 1_010
        )

        let controller = WINetworkViewController(store: store, queryModel: queryModel)
        controller.loadViewIfNeeded()
        let selected = try #require(
            queryModel.displayEntries.first(where: { $0.requestID == 112 })
        )

        store.selectEntry(selected)

        #expect(store.selectedEntry?.id == selected.id)
    }

    @Test
    func networkTabLifecycleCanRepeatWithoutLeaking() async throws {
        let store = WINetworkStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(store: store)
        try applyRequestStart(
            to: store,
            requestID: 201,
            url: "https://example.com/resource.js",
            initiator: "script",
            monotonicMs: 1_000
        )

        var controller: WINetworkViewController? = WINetworkViewController(
            store: store,
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

    @Test
    func networkContainerCloseResetsStoreState() throws {
        let container = WINetworkContainerViewController()
        let window = NSWindow(contentViewController: container)
        container.loadViewIfNeeded()
        try applyRequestStart(
            to: container.store,
            requestID: 301,
            url: "https://example.com/close-reset.json",
            initiator: "fetch",
            monotonicMs: 1_000
        )
        let selectedEntry = try #require(container.store.store.entries.first)
        container.store.selectEntry(selectedEntry)

        #expect(container.store.store.entries.count == 1)
        #expect(container.store.selectedEntry?.id == selectedEntry.id)

        window.orderOut(nil)
        window.contentViewController = nil
        container.viewDidDisappear()

        #expect(container.store.store.entries.isEmpty)
        #expect(container.store.selectedEntry == nil)
        #expect(container.sessionController.networkStore.session.mode == .stopped)
    }

    @Test
    func standaloneNetworkViewCloseDoesNotResetOwnedStore() throws {
        let store = WINetworkStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(store: store)
        let controller = WINetworkViewController(store: store, queryModel: queryModel)
        let window = NSWindow(contentViewController: controller)
        controller.loadViewIfNeeded()
        try applyRequestStart(
            to: store,
            requestID: 302,
            url: "https://example.com/pure-view.json",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        window.orderOut(nil)
        window.contentViewController = nil
        controller.viewDidDisappear()

        #expect(store.store.entries.count == 1)
    }

    private func applyRequestStart(
        to store: WINetworkStore,
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
        store.store.applyEvent(event)
    }

    private func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> HTTPNetworkEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(NetworkEventPayload.self, from: data)
        return try #require(HTTPNetworkEvent(payload: decoded, sessionID: sessionID))
    }
}
#endif

import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor


struct NetworkInspectorAppKitTests {
    @Test
    func networkTabSelectsFirstEntryWhenEntriesExist() throws {
        let inspector = WINetworkModel(session: NetworkSession())
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

        let controller = WINetworkViewController(inspector: inspector)
        controller.loadViewIfNeeded()

        #expect(inspector.selectedEntry?.id == inspector.displayEntries.first?.id)
    }

    @Test
    func networkTabLifecycleCanRepeatWithoutLeaking() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 201,
            url: "https://example.com/resource.js",
            initiator: "script",
            monotonicMs: 1_000
        )

        var controller: WINetworkViewController? = WINetworkViewController(inspector: inspector)
        weak let weakController = controller
        controller?.loadViewIfNeeded()
        let lifecycleTask = Task { @MainActor in
            for _ in 0..<8 {
                controller?.viewWillAppear()
                await Task.yield()
                controller?.viewDidDisappear()
                await Task.yield()
            }
        }
        let completed = await valueWithinTimeout(seconds: 10) {
            await lifecycleTask.value
            return true
        }
        #expect(completed == true)

        controller = nil
        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(weakController == nil)
    }

    private func applyRequestStart(
        to inspector: WINetworkModel,
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

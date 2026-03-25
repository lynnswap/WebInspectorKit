import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
@Suite(.serialized)
struct NetworkInspectorAppKitTests {
    @Test
    func networkTabUsesNativeContentListAndDetailControllers() {
        let inspector = WINetworkModel(session: NetworkSession())
        let controller = WINetworkViewController(inspector: inspector)

        controller.loadViewIfNeeded()

        #expect(controller.splitViewItems.count == 2)
        #expect(controller.splitViewItems.first?.behavior == .contentList)
        #expect(controller.listViewControllerForTesting.displayedRowCountForTesting == 0)
        #expect(controller.detailViewControllerForTesting.isShowingEmptyStateForTesting == true)
    }

    @Test
    func networkTabDoesNotAutoSelectEntryWhenEntriesExist() throws {
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

        #expect(inspector.selectedEntry == nil)
    }

    @Test
    func networkTabListTracksSearchAndFilterResults() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 301,
            url: "https://example.com/api/first.json",
            initiator: "xhr",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: inspector,
            requestID: 302,
            url: "https://example.com/assets/app.js",
            initiator: "script",
            monotonicMs: 1_010
        )

        let controller = WINetworkViewController(inspector: inspector)
        controller.loadViewIfNeeded()
        #expect(controller.listViewControllerForTesting.displayedRowCountForTesting == 2)

        inspector.searchText = "first"
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.displayedRowCountForTesting == 1
        })

        inspector.searchText = ""
        inspector.activeResourceFilters = [.script]
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.displayedRowCountForTesting == 1
        })

        inspector.activeResourceFilters = []
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.displayedRowCountForTesting == 2
        })
    }

    @Test
    func networkTabUpdatesDetailWhenSelectionChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
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

        let controller = WINetworkViewController(inspector: inspector)
        controller.loadViewIfNeeded()
        let selected = try #require(
            inspector.displayEntries.first(where: { $0.requestID == 112 })
        )

        inspector.selectEntry(selected)
        #expect(inspector.selectedEntry?.id == selected.id)
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.selectedRowForTesting >= 0
        })
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.renderedSectionTitlesForTesting.contains("Overview")
        })
    }

    @Test
    func networkTabUpdatesDetailWhenSelectedEntryContentChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 113,
            url: "https://example.com/live-update",
            initiator: "xhr",
            monotonicMs: 1_000
        )

        let controller = WINetworkViewController(inspector: inspector)
        controller.loadViewIfNeeded()
        let selected = try #require(inspector.displayEntries.first(where: { $0.requestID == 113 }))

        inspector.selectEntry(selected)
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.renderedSectionTitlesForTesting.contains("Overview")
        })

        let initialGeneration = inspector.displayEntriesGeneration
        selected.errorDescription = "Request failed"

        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.renderedSectionTitlesForTesting.contains("Error")
        })
        #expect(await waitUntilAsync(timeout: 0.2) {
            inspector.displayEntriesGeneration == initialGeneration
        })
    }

    @Test
    func networkTabUpdatesBodyTitleWhenContentTypeHeaderChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 114,
            url: "https://example.com/body-title",
            initiator: "xhr",
            monotonicMs: 1_000
        )

        let entry = try #require(inspector.displayEntries.first(where: { $0.requestID == 114 }))
        entry.responseBody = NetworkBody(
            kind: .text,
            preview: "{\"status\":\"ok\"}",
            full: "{\"status\":\"ok\"}",
            role: .response
        )

        let controller = WINetworkViewController(inspector: inspector)
        controller.loadViewIfNeeded()
        inspector.selectEntry(entry)

        guard let responseButton = try await waitForResponseBodyButton(in: controller) else {
            Issue.record("Expected response body button")
            return
        }

        let initialGeneration = inspector.displayEntriesGeneration
        #expect(responseButton.title.contains("TEXT"))

        entry.responseHeaders = NetworkHeaders(dictionary: ["content-type": "application/json; charset=utf-8"])

        #expect(await waitUntilAsync(timeout: 1.0) {
            responseButton.title.contains("application/json")
        })
        #expect(await waitUntilAsync(timeout: 0.2) {
            inspector.displayEntriesGeneration == initialGeneration
        })
    }

    @Test
    func networkModelGenerationDoesNotBumpWhenSelectionChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 211,
            url: "https://example.com/selection",
            initiator: "xhr",
            monotonicMs: 1_000
        )

        let initialGeneration = inspector.displayEntriesGeneration
        let entry = try #require(inspector.displayEntries.first(where: { $0.requestID == 211 }))
        inspector.selectEntry(entry)

        #expect(await waitUntilAsync(timeout: 0.2) {
            inspector.displayEntriesGeneration == initialGeneration
        })
    }

    @Test
    func networkModelGenerationBumpsWhenEntryIsAppended() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 213,
            url: "https://example.com/response",
            initiator: "xhr",
            monotonicMs: 1_000
        )

        let initialGeneration = inspector.displayEntriesGeneration
        try applyRequestStart(
            to: inspector,
            requestID: 214,
            url: "https://example.com/appended",
            initiator: "script",
            monotonicMs: 1_050
        )

        #expect(await waitUntilAsync(timeout: 1.0) {
            inspector.displayEntriesGeneration > initialGeneration
        })
    }

    @Test
    func networkModelGenerationDoesNotBumpForFetchedBodySizeMetadata() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 214,
            url: "https://example.com/body",
            initiator: "xhr",
            monotonicMs: 1_000
        )

        let entry = try #require(inspector.displayEntries.first)
        inspector.selectEntry(entry)
        let initialGeneration = inspector.displayEntriesGeneration
        entry.applyFetchedBodySizeMetadata(
            from: NetworkBody(
                kind: .text,
                preview: "body",
                full: "body",
                size: 256,
                role: .response
            )
        )

        #expect(await waitUntilAsync(timeout: 0.2) {
            inspector.displayEntriesGeneration == initialGeneration
        })
    }

    @Test
    func networkTabBodyPreviewOpensSheetAndUsesObjectTreeForJSONBody() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 401,
            url: "https://example.com/preview.json",
            initiator: "xhr",
            monotonicMs: 1_000
        )
        guard let entry = inspector.displayEntries.first else {
            Issue.record("Expected display entry")
            return
        }

        entry.mimeType = "application/json"
        entry.responseHeaders = NetworkHeaders(dictionary: ["content-type": "application/json"])
        entry.responseBody = NetworkBody(
            kind: .text,
            preview: "{\"result\":\"ok\",\"items\":[1,2,3]}",
            full: "{\"result\":\"ok\",\"items\":[1,2,3]}",
            role: .response
        )
        let controller = WINetworkViewController(inspector: inspector)
        let window = NSWindow(contentViewController: controller)
        controller.loadViewIfNeeded()
        window.makeKeyAndOrderFront(nil)
        inspector.selectEntry(entry)

        let hasResponseButton = await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.responseBodyButtonForTesting != nil
        }
        #expect(hasResponseButton)

        guard let responseButton = controller.detailViewControllerForTesting.responseBodyButtonForTesting else {
            Issue.record("Expected response body button")
            return
        }

        responseButton.performClick(nil)

        guard let preview = controller.detailViewControllerForTesting.presentedBodyPreviewViewControllerForTesting else {
            Issue.record("Expected body preview sheet")
            return
        }

        preview.loadViewIfNeeded()
        let rendered = await waitUntilAsync(timeout: 1.0) {
            preview.availableModesForTesting.isEmpty == false
        }
        #expect(rendered)

        #expect(preview.availableModesForTesting.contains(.objectTree))
        #expect(preview.currentModeForTesting == .objectTree)

        let replacementBody = NetworkBody(
            kind: .text,
            preview: "{\"result\":\"updated\",\"items\":[4,5,6]}",
            full: "{\"result\":\"updated\",\"items\":[4,5,6]}",
            role: .response
        )
        let generationBeforeReplacement = inspector.displayEntriesGeneration
        entry.responseBody = replacementBody

        #expect(await waitUntilAsync(timeout: 1.0) {
            preview.currentBodyIdentityForTesting == ObjectIdentifier(replacementBody)
        })
        #expect(await waitUntilAsync(timeout: 0.2) {
            inspector.displayEntriesGeneration == generationBeforeReplacement
        })

        inspector.selectEntry(nil)
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.presentedBodyPreviewViewControllerForTesting == nil
        })
    }

    @Test
    func networkTabClearsVisibleSelectionWhenSelectedEntryIsRemoved() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 501,
            url: "https://example.com/removed",
            initiator: "xhr",
            monotonicMs: 1_000
        )

        let controller = WINetworkViewController(inspector: inspector)
        controller.loadViewIfNeeded()

        let selectedEntryID = try #require(inspector.displayEntries.first?.id)
        inspector.selectEntry(inspector.displayEntries.first)
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.selectedRowForTesting == 0
        })

        inspector.store.clear()

        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.displayedRowCountForTesting == 0
        })
        #expect(await waitUntilAsync(timeout: 1.0) {
            inspector.selectedEntry == nil
        })
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.listViewControllerForTesting.selectedRowForTesting == -1
        })
        #expect(await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.isShowingEmptyStateForTesting == true
        })
        #expect(inspector.store.entries.first?.id != selectedEntryID)
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
        inspector.store.apply(event, sessionID: "")
    }

    private func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> NetworkWire.PageHook.Event {
        _ = sessionID
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(NetworkWire.PageHook.Event.self, from: data)
    }

    private func waitForResponseBodyButton(
        in controller: WINetworkViewController
    ) async throws -> NSButton? {
        let exists = await waitUntilAsync(timeout: 1.0) {
            controller.detailViewControllerForTesting.responseBodyButtonForTesting != nil
        }
        #expect(exists)
        return controller.detailViewControllerForTesting.responseBodyButtonForTesting
    }

    private func waitUntilAsync(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await MainActor.run(body: condition)
    }
}
#endif

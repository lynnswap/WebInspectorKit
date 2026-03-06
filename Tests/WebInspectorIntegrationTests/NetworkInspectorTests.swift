import Foundation
import Testing
import ObservationBridge
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor


struct NetworkInspectorTests {
    @Test
    func applyFetchedBodyUpdatesDecodedBodyLengthForResponseBody() {
        let entry = makeEntry()
        let target = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: "resp_ref",
            formEntries: [],
            fetchState: .inline,
            role: .response
        )
        let fetched = NetworkBody(
            kind: .text,
            preview: nil,
            full: "response body",
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: nil,
            reference: "resp_ref",
            formEntries: [],
            fetchState: .full,
            role: .response
        )

        entry.applyFetchedBody(fetched, to: target)

        #expect(target.fetchState == .full)
        #expect(target.size == 13)
        #expect(entry.decodedBodyLength == 13)
    }

    @Test
    func applyFetchedBodyUpdatesRequestBodyBytesForRequestBody() {
        let entry = makeEntry()
        let target = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: "req_ref",
            formEntries: [],
            fetchState: .inline,
            role: .request
        )
        let fetched = NetworkBody(
            kind: .text,
            preview: "request preview",
            full: nil,
            size: 256,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: "req_ref",
            formEntries: [],
            fetchState: .full,
            role: .request
        )

        entry.applyFetchedBody(fetched, to: target)

        #expect(target.fetchState == .full)
        #expect(target.size == 256)
        #expect(entry.requestBodyBytesSent == 256)
    }

    @Test
    func handleOnlyBodyStartsInlineStateForDeferredFetch() {
        let body = NetworkBody(
            kind: .text,
            preview: "preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: nil,
            handle: NSObject(),
            formEntries: [],
            fetchState: nil,
            role: .response
        )

        #expect(body.canFetchBody)
        #expect(body.fetchState == .inline)
    }

    @Test
    func selectingEntryWithExistingResponseBodyDoesNotAutoFetch() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("selectEntry should not fetch automatically")
            return nil
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        inspector.selectEntry(entry)

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(body.fetchState == .inline)
    }

    @Test
    func requestBodyIfNeededFetchesInlineBodyOnce() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            self.makeFetchedBody(full: "resolved response", reference: ref, role: role)
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        inspector.attach(to: WKWebView(frame: .zero))
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        inspector.requestBodyIfNeeded(for: entry, role: .response)

        let fetched = await waitUntil {
            fetcher.fetchRefs == ["resp_ref"]
                && body.fetchState == .full
                && body.full == "resolved response"
        }
        #expect(fetched)
        #expect(fetcher.fetchRefs.count == 1)

        inspector.requestBodyIfNeeded(for: entry, role: .response)
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.count == 1)
    }

    @Test
    func requestBodyIfNeededDoesNotRetryFailedBody() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in nil }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        inspector.attach(to: WKWebView(frame: .zero))
        let entry = makeEntry()
        let body = makeBody(reference: "failed-ref", role: .response)
        entry.responseBody = body

        inspector.requestBodyIfNeeded(for: entry, role: .response)

        let failed = await waitUntil {
            body.fetchState == .failed(.unavailable)
        }
        #expect(failed)
        #expect(fetcher.fetchRefs.count == 1)

        inspector.requestBodyIfNeeded(for: entry, role: .response)
        await Task.yield()

        #expect(fetcher.fetchRefs.count == 1)
    }

    @Test
    func requestBodyIfNeededDoesNothingWhileDetached() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("detached inspector should not fetch")
            return nil
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let entry = makeEntry()
        let body = makeBody(reference: "detached-ref", role: .response)
        entry.responseBody = body

        inspector.requestBodyIfNeeded(for: entry, role: .response)

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(body.fetchState == .inline)
    }

    @Test
    func requestBodyIfNeededRemainsNoOpAfterDetach() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("detached inspector should not fetch")
            return nil
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        inspector.attach(to: WKWebView(frame: .zero))
        inspector.detach()

        let entry = makeEntry()
        let body = makeBody(reference: "detach-ref", role: .response)
        entry.responseBody = body

        inspector.requestBodyIfNeeded(for: entry, role: .response)

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(body.fetchState == .inline)
    }

    @Test
    func displayEntriesAppliesSearchResourceFilterAndSortTogether() throws {
        let inspector = WINetworkModel(session: NetworkSession())

        try applyRequestStart(
            to: inspector,
            requestID: 1,
            url: "https://example.com/index.html",
            initiator: "document",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: inspector,
            requestID: 2,
            url: "https://cdn.example.com/image.png",
            initiator: "img",
            monotonicMs: 1_010
        )
        try applyRequestStart(
            to: inspector,
            requestID: 3,
            url: "https://cdn.example.com/app.js",
            initiator: "script",
            monotonicMs: 1_020
        )

        inspector.searchText = "cdn"
        inspector.activeResourceFilters = [.image, .script]
        inspector.sortDescriptors = [
            SortDescriptor(\.requestID, order: .reverse)
        ]

        #expect(inspector.displayEntries.map(\.requestID) == [3, 2])

        inspector.activeResourceFilters = [.all]
        #expect(inspector.effectiveResourceFilters.isEmpty)
        #expect(inspector.displayEntries.map(\.requestID) == [3, 2])
    }

    @Test
    func assigningEmptyActiveFiltersClearsEffectiveFilters() {
        let inspector = WINetworkModel(session: NetworkSession())

        inspector.activeResourceFilters = [.image, .script]
        #expect(inspector.effectiveResourceFilters == [.image, .script])

        inspector.activeResourceFilters = []
        #expect(inspector.activeResourceFilters.isEmpty)
        #expect(inspector.effectiveResourceFilters.isEmpty)
    }

    @Test
    func clearResetsSelectedEntry() throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 11,
            url: "https://example.com/detail",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        let selectedEntry = try #require(inspector.store.entries.first)
        inspector.selectEntry(selectedEntry)

        inspector.clear()

        #expect(inspector.selectedEntry == nil)
        #expect(inspector.store.entries.isEmpty)
        #expect(inspector.displayEntries.isEmpty)
    }

    @Test
    func clearKeepsSearchAndResourceFiltersWhileResettingEntriesAndSelection() throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 31,
            url: "https://example.com/filter-target.js",
            initiator: "script",
            monotonicMs: 1_000
        )
        let selectedEntry = try #require(inspector.store.entries.first)
        inspector.selectEntry(selectedEntry)
        inspector.searchText = "filter-target"
        inspector.activeResourceFilters = [.script]

        inspector.clear()

        #expect(inspector.selectedEntry == nil)
        #expect(inspector.store.entries.isEmpty)
        #expect(inspector.displayEntries.isEmpty)
        #expect(inspector.searchText == "filter-target")
        #expect(inspector.activeResourceFilters == [.script])
        #expect(inspector.effectiveResourceFilters == [.script])
    }

    @Test
    func displayEntriesKeepsBodylessBufferedStyleEntriesSearchableAndFilterable() throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 21,
            url: "https://example.com/buffered-endpoint",
            initiator: "fetch",
            monotonicMs: 1_000
        )
        let finish = try decodeEvent([
            "kind": "loadingFinished",
            "requestId": 21,
            "initiator": "fetch",
            "time": [
                "monotonicMs": 1_120.0,
                "wallMs": 1_700_000_000_120.0
            ]
        ])
        inspector.store.applyEvent(finish)

        inspector.searchText = "buffered-endpoint"
        inspector.activeResourceFilters = [.xhrFetch]

        let displayed = inspector.displayEntries
        #expect(displayed.count == 1)
        let entry = try #require(displayed.first)
        #expect(entry.requestID == 21)
        #expect(entry.requestBody == nil)
        #expect(entry.responseBody == nil)
    }

    @Test
    func selectedEntryRemainsWhenFilterExcludesDisplayedEntries() throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 61,
            url: "https://example.com/selected.js",
            initiator: "script",
            monotonicMs: 1_000
        )
        try applyRequestStart(
            to: inspector,
            requestID: 62,
            url: "https://example.com/other.css",
            initiator: "stylesheet",
            monotonicMs: 1_010
        )

        let selectedEntry = try #require(
            inspector.store.entries.first(where: { $0.requestID == 61 })
        )
        inspector.selectEntry(selectedEntry)
        inspector.activeResourceFilters = [.stylesheet]

        #expect(inspector.displayEntries.map(\.requestID) == [62])
        #expect(inspector.selectedEntry?.id == selectedEntry.id)
    }

    @Test
    func selectedEntryClearsWhenPrunedFromStoreByRetentionLimit() async throws {
        let inspector = WINetworkModel(
            session: NetworkSession(configuration: .init(maxEntries: 1))
        )
        try applyRequestStart(
            to: inspector,
            requestID: 71,
            url: "https://example.com/old",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        let initiallySelectedID = try #require(inspector.store.entries.first?.id)
        inspector.selectEntry(inspector.store.entries.first)

        try applyRequestStart(
            to: inspector,
            requestID: 72,
            url: "https://example.com/new",
            initiator: "fetch",
            monotonicMs: 1_010
        )

        let cleared = await waitUntil {
            inspector.selectedEntry == nil
        }
        #expect(cleared)
        #expect(inspector.store.entries.count == 1)
        #expect(inspector.store.entries.first?.requestID == 72)
        #expect(inspector.store.entries.first?.id != initiallySelectedID)
    }

    @Test
    func displayEntriesUpdatesWhenObservedEntryStateChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 81,
            url: "https://example.com/stateful",
            initiator: "fetch",
            monotonicMs: 1_000
        )
        let responseReceived = try decodeEvent([
            "kind": "responseReceived",
            "requestId": 81,
            "status": 404,
            "statusText": "Not Found",
            "mimeType": "application/json",
            "time": [
                "monotonicMs": 1_020.0,
                "wallMs": 1_700_000_000_020.0
            ]
        ])
        inspector.store.applyEvent(responseReceived)

        let updated = await waitUntil {
            inspector.displayEntries.first?.statusLabel == "404"
        }
        #expect(updated)
        #expect(inspector.displayEntries.first?.statusSeverity == .warning)
        #expect(inspector.displayEntries.first?.fileTypeLabel == "json")
    }

    @Test
    func observeSearchTextSuppressesDuplicateConsecutiveStates() async {
        let inspector = WINetworkModel(session: NetworkSession())
        var emittedValues: [String] = []
        var observationHandles = Set<ObservationHandle>()

        inspector.observeTask(
            \.searchText,
            options: [.removeDuplicates]
        ) { value in
            emittedValues.append(value)
        }
        .store(in: &observationHandles)

        let receivedInitial = await waitUntil { emittedValues.count >= 1 }
        #expect(receivedInitial)

        inspector.searchText = "dup-keyword"
        let receivedUpdated = await waitUntil { emittedValues.count >= 2 }
        #expect(receivedUpdated)

        inspector.searchText = "dup-keyword"
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(emittedValues.count == 2)
        #expect(emittedValues.last == "dup-keyword")
    }

    @Test
    func observeSearchTextStopsEmittingAfterCancel() async {
        let inspector = WINetworkModel(session: NetworkSession())
        var callbackCount = 0

        let handle = inspector.observeTask(
            \.searchText,
            options: [.removeDuplicates]
        ) { _ in
            callbackCount += 1
        }

        let receivedInitial = await waitUntil { callbackCount >= 1 }
        #expect(receivedInitial)

        handle.cancel()
        await Task.yield()
        let countAfterCancel = callbackCount

        inspector.searchText = "after-cancel"
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(callbackCount == countAfterCancel)
    }

    private func makeEntry() -> NetworkEntry {
        NetworkEntry(
            sessionID: "session",
            requestID: 1,
            url: "https://example.com",
            method: "GET",
            requestHeaders: NetworkHeaders(),
            startTimestamp: 0,
            wallTime: nil
        )
    }

    private func makeBody(
        reference: String,
        role: NetworkBody.Role
    ) -> NetworkBody {
        NetworkBody(
            kind: .text,
            preview: "preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: reference,
            formEntries: [],
            fetchState: .inline,
            role: role
        )
    }

    private func makeFetchedBody(
        full: String,
        reference: String?,
        role: NetworkBody.Role
    ) -> NetworkBody {
        NetworkBody(
            kind: .text,
            preview: nil,
            full: full,
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: nil,
            reference: reference,
            formEntries: [],
            fetchState: .full,
            role: role
        )
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

    private func waitUntil(
        maxTicks: Int = 512,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class StubNetworkBodyFetcher: NetworkBodyFetching {
    private let onFetch: @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBody?
    private(set) var fetchRefs: [String?] = []

    init(
        onFetch: @escaping @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBody?
    ) {
        self.onFetch = onFetch
    }

    func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        fetchRefs.append(ref)
        return await onFetch(ref, handle, role)
    }
}

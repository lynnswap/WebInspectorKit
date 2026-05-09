import Foundation
import Testing
import ObservationBridge
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
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
    func selectingEntryFetchesSelectedBodiesWhenAttached() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            switch ref {
            case "req_ref":
                return self.makeFetchedBody(full: "resolved request", reference: ref, role: role)
            case "resp_ref":
                return self.makeFetchedBody(full: "resolved response", reference: ref, role: role)
            default:
                Issue.record("unexpected body ref: \(ref ?? "nil")")
                return nil
            }
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let webView = WKWebView(frame: .zero)
        await inspector.attach(to: webView)
        let entry = makeEntry()
        entry.requestBody = makeBody(reference: "req_ref", role: .request)
        entry.responseBody = makeBody(reference: "resp_ref", role: .response)

        inspector.selectEntry(entry)

        let fetched = await waitUntil {
            fetcher.fetchRefs.count == 2
                && Set(fetcher.fetchRefs.compactMap { $0 }) == Set(["req_ref", "resp_ref"])
                && entry.requestBody?.full == "resolved request"
                && entry.responseBody?.full == "resolved response"
        }
        #expect(fetched)
        #expect(fetcher.fetchRefs.count == 2)
    }

    @Test
    func selectingEntryWhileDetachedWaitsForAttachBeforeFetching() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            self.makeFetchedBody(full: "resolved response", reference: ref, role: role)
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

        let webView = WKWebView(frame: .zero)
        await inspector.attach(to: webView)

        let fetched = await waitUntil {
            fetcher.fetchRefs == ["resp_ref"]
                && body.fetchState == .full
                && body.full == "resolved response"
        }
        #expect(fetched)
    }

    @Test
    func selectedEntryBodyAppearanceTriggersFetch() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            self.makeFetchedBody(full: "late body", reference: ref, role: role)
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let webView = WKWebView(frame: .zero)
        await inspector.attach(to: webView)
        let entry = makeEntry()

        inspector.selectEntry(entry)

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.isEmpty)

        let body = makeBody(reference: "late-ref", role: .response)
        entry.responseBody = body

        let fetched = await waitUntil {
            fetcher.fetchRefs == ["late-ref"]
                && body.fetchState == .full
                && body.full == "late body"
        }
        #expect(fetched)
    }

    @Test
    func selectingNewEntryCancelsPreviousSelectionFetch() async {
        let slowFetchGate = NetworkFetchGate()
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            if ref == "slow-ref" {
                await slowFetchGate.markStarted()
                while true {
                    if Task.isCancelled {
                        await slowFetchGate.markCancelled()
                        return nil
                    }
                    await Task.yield()
                }
            }
            return self.makeFetchedBody(full: "fast body", reference: ref, role: role)
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let webView = WKWebView(frame: .zero)
        await inspector.attach(to: webView)

        let firstEntry = makeEntry()
        let firstBody = makeBody(reference: "slow-ref", role: .response)
        firstEntry.responseBody = firstBody

        let secondEntry = makeEntry(requestID: 2)
        let secondBody = makeBody(reference: "fast-ref", role: .response)
        secondEntry.responseBody = secondBody

        inspector.selectEntry(firstEntry)
        await slowFetchGate.waitUntilStarted()
        #expect(firstBody.fetchState == .fetching)

        inspector.selectEntry(secondEntry)

        let secondFetched = await waitUntil {
            secondBody.full == "fast body" && secondBody.fetchState == .full
        }
        #expect(secondFetched)

        await slowFetchGate.waitUntilCancelled()

        let firstCancelled = await waitUntil {
            firstBody.fetchState == .inline && firstBody.full == nil
        }
        #expect(firstCancelled)
        #expect(secondBody.fetchState == .full)
    }

    @Test
    func detachClearsSelectedEntrySoReattachDoesNotFetchStaleBody() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("reattach should not fetch cleared selection")
            return nil
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let entry = makeEntry()
        let body = makeBody(reference: "stale-ref", role: .response)
        entry.responseBody = body
        inspector.selectEntry(entry)

        await inspector.detach()
        let webView = WKWebView(frame: .zero)
        await inspector.attach(to: webView)

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
    func clearResetsSelectedEntry() async throws {
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

        await inspector.clear()

        #expect(inspector.selectedEntry == nil)
        #expect(inspector.store.entries.isEmpty)
        #expect(inspector.displayEntries.isEmpty)
    }

    @Test
    func clearKeepsSearchAndResourceFiltersWhileResettingEntriesAndSelection() async throws {
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

        await inspector.clear()

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
        inspector.store.apply(finish, sessionID: "")

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
    func selectedEntryClearsWhenStoreIsClearedDirectly() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 73,
            url: "https://example.com/direct-clear",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        inspector.selectEntry(inspector.store.entries.first)
        inspector.store.clear()

        let cleared = await waitUntil {
            inspector.selectedEntry == nil
        }
        #expect(cleared)
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
        inspector.store.apply(responseReceived, sessionID: "")

        let updated = await waitUntil {
            inspector.displayEntries.first?.statusLabel == "404"
        }
        #expect(updated)
        #expect(inspector.displayEntries.first?.statusSeverity == .warning)
        #expect(inspector.displayEntries.first?.fileTypeLabel == "json")
    }

    @Test
    func displayEntriesGenerationBumpsWhenResponseUpdateChangesSearchableFields() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 82,
            url: "https://example.com/searchable",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        inspector.searchText = "404"
        let initialGeneration = inspector.displayEntriesGeneration

        let responseReceived = try decodeEvent([
            "kind": "responseReceived",
            "requestId": 82,
            "status": 404,
            "statusText": "Not Found",
            "mimeType": "application/json",
            "time": [
                "monotonicMs": 1_020.0,
                "wallMs": 1_700_000_000_020.0
            ]
        ])
        inspector.store.apply(responseReceived, sessionID: "")

        let updated = await waitUntil {
            inspector.displayEntriesGeneration > initialGeneration
                && inspector.displayEntries.map(\.requestID) == [82]
        }
        #expect(updated)
    }

    @Test
    func displayEntriesGenerationBumpsWhenCompletionUpdateChangesSortableFields() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 83,
            url: "https://example.com/sortable",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        let initialGeneration = inspector.displayEntriesGeneration

        let completed = try decodeEvent([
            "kind": "loadingFinished",
            "requestId": 83,
            "encodedBodyLength": 512,
            "decodedBodySize": 1_024,
            "time": [
                "monotonicMs": 1_080.0,
                "wallMs": 1_700_000_000_080.0
            ]
        ])
        inspector.store.apply(completed, sessionID: "")

        let updated = await waitUntil {
            guard let entry = inspector.displayEntries.first else {
                return false
            }
            return inspector.displayEntriesGeneration > initialGeneration
                && entry.requestID == 83
                && entry.phase == .completed
                && entry.duration != nil
                && entry.encodedBodyLength == 512
                && entry.decodedBodyLength == 1_024
        }
        #expect(updated)
    }

    @Test
    func observeSearchTextIgnoresUnchangedConsecutiveAssignments() async {
        let inspector = WINetworkModel(session: NetworkSession())
        var emittedValues: [String] = []
        let observationScope = ObservationScope()

        inspector.observeTask(
            \.searchText
        ) { value in
            emittedValues.append(value)
        }
        .store(in: observationScope)

        let receivedInitial = await waitUntil { emittedValues.count >= 1 }
        #expect(receivedInitial)

        inspector.searchText = "dup-keyword"
        let receivedUpdated = await waitUntil { emittedValues.count >= 2 }
        #expect(receivedUpdated)

        inspector.searchText = "dup-keyword"
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(emittedValues.count == 2)
        #expect(emittedValues.last == "dup-keyword")
    }

    @Test
    func observeSearchTextStopsEmittingAfterCancel() async {
        let inspector = WINetworkModel(session: NetworkSession())
        var callbackCount = 0
        let observationScope = ObservationScope()

        inspector.observeTask(
            \.searchText
        ) { _ in
            callbackCount += 1
        }
        .store(in: observationScope)

        let receivedInitial = await waitUntil { callbackCount >= 1 }
        #expect(receivedInitial)

        observationScope.cancelAll()
        await Task.yield()
        let countAfterCancel = callbackCount

        inspector.searchText = "after-cancel"
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(callbackCount == countAfterCancel)
    }

    private func makeEntry(requestID: Int = 1) -> NetworkEntry {
        NetworkEntry(
            sessionID: "session",
            requestID: requestID,
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
        inspector.store.apply(event, sessionID: "")
    }

    private func decodeEvent(_ payload: [String: Any], sessionID: String = "") throws -> NetworkEntry.Update {
        try NetworkTestHelpers.decodeEvent(payload, sessionID: sessionID)
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

private actor NetworkFetchGate {
    private var didStart = false
    private var didCancel = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancelContinuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !didStart else {
            return
        }
        didStart = true
        let continuations = startContinuations
        startContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func markCancelled() {
        guard !didCancel else {
            return
        }
        didCancel = true
        let continuations = cancelContinuations
        cancelContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    func waitUntilCancelled() async {
        guard !didCancel else {
            return
        }
        await withCheckedContinuation { continuation in
            cancelContinuations.append(continuation)
        }
    }
}

@MainActor
private final class StubNetworkBodyFetcher: NetworkBodyFetching {
    private let onFetch: @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBodyFetchResult
    private(set) var fetchRefs: [String?] = []

    init(
        onFetch: @escaping @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBody?
    ) {
        self.onFetch = { ref, handle, role in
            guard let body = await onFetch(ref, handle, role) else {
                return .bodyUnavailable
            }
            return .fetched(body)
        }
    }

    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        switch role {
        case .request, .response:
            true
        }
    }

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> NetworkBodyFetchResult {
        let reference = locator.reference
        let handle = locator.handle
        fetchRefs.append(reference)
        return await onFetch(reference, handle, role)
    }
}

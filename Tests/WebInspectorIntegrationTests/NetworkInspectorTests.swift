import Foundation
import Testing
import ObservationBridge
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor

@Suite(.serialized, .webKitIsolated)
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
    func selectingEntryFetchesSelectedBodiesWhenAttached() async throws {
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
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let webView = makeIsolatedTestWebView()
        inspector.attach(to: webView)
        let entry = makeEntry()
        entry.requestBody = makeBody(reference: "req_ref", role: .request)
        entry.responseBody = makeBody(reference: "resp_ref", role: .response)
        let requestBody = try #require(entry.requestBody)
        let responseBody = try #require(entry.responseBody)
        let requestBodyStates = fetchStateRecorder(for: requestBody)
        let responseBodyStates = fetchStateRecorder(for: responseBody)

        inspector.selectEntry(entry)

        _ = await requestBodyStates.next(where: { $0 == "full" })
        _ = await responseBodyStates.next(where: { $0 == "full" })

        #expect(fetcher.fetchRefs.count == 2)
        #expect(Set(fetcher.fetchRefs.compactMap { $0 }) == Set(["req_ref", "resp_ref"]))
        #expect(entry.requestBody?.full == "resolved request")
        #expect(entry.responseBody?.full == "resolved response")
    }

    @Test
    func selectingEntryWhileDetachedWaitsForAttachBeforeFetching() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            self.makeFetchedBody(full: "resolved response", reference: ref, role: role)
        }
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        inspector.selectEntry(entry)

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(body.fetchState == .inline)

        let webView = makeIsolatedTestWebView()
        let bodyStates = fetchStateRecorder(for: body)
        inspector.attach(to: webView)

        _ = await bodyStates.next(where: { $0 == "full" })
        #expect(fetcher.fetchRefs == ["resp_ref"])
        #expect(body.fetchState == .full)
        #expect(body.full == "resolved response")
    }

    @Test
    func selectedEntryBodyAppearanceTriggersFetch() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            self.makeFetchedBody(full: "late body", reference: ref, role: role)
        }
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let webView = makeIsolatedTestWebView()
        inspector.attach(to: webView)
        let entry = makeEntry()

        inspector.selectEntry(entry)

        #expect(fetcher.fetchRefs.isEmpty)

        let body = makeBody(reference: "late-ref", role: .response)
        let bodyStates = fetchStateRecorder(for: body)
        entry.responseBody = body

        _ = await bodyStates.next(where: { $0 == "full" })
        #expect(fetcher.fetchRefs == ["late-ref"])
        #expect(body.fetchState == .full)
        #expect(body.full == "late body")
    }

    @Test
    func selectingNewEntryCancelsPreviousSelectionFetch() async {
        let slowFetchStarted = AsyncGate()
        let releaseSlowFetch = AsyncGate()
        let slowFetchFinished = AsyncGate()
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            if ref == "slow-ref" {
                await slowFetchStarted.open()
                await releaseSlowFetch.wait()
                await slowFetchFinished.open()
                return self.makeFetchedBody(full: "slow body", reference: ref, role: role)
            }
            return self.makeFetchedBody(full: "fast body", reference: ref, role: role)
        }
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let webView = makeIsolatedTestWebView()
        inspector.attach(to: webView)

        let firstEntry = makeEntry()
        let firstBody = makeBody(reference: "slow-ref", role: .response)
        firstEntry.responseBody = firstBody

        let secondEntry = makeEntry(requestID: 2)
        let secondBody = makeBody(reference: "fast-ref", role: .response)
        secondEntry.responseBody = secondBody
        let firstBodyStates = fetchStateRecorder(for: firstBody)
        let secondBodyStates = fetchStateRecorder(for: secondBody)

        inspector.selectEntry(firstEntry)
        _ = await firstBodyStates.next(where: { $0 == "fetching" })
        await slowFetchStarted.wait()

        inspector.selectEntry(secondEntry)

        _ = await secondBodyStates.next(where: { $0 == "full" })

        await releaseSlowFetch.open()
        await slowFetchFinished.wait()

        #expect(firstBody.fetchState == .inline)
        #expect(firstBody.full == nil)
        #expect(secondBody.fetchState == .full)
    }

    @Test
    func detachClearsSelectedEntrySoReattachDoesNotFetchStaleBody() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("reattach should not fetch cleared selection")
            return nil
        }
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let entry = makeEntry()
        let body = makeBody(reference: "stale-ref", role: .response)
        entry.responseBody = body
        inspector.selectEntry(entry)

        inspector.detach()
        let webView = makeIsolatedTestWebView()
        inspector.attach(to: webView)

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(body.fetchState == .inline)
    }

    @Test
    func displayEntriesAppliesSearchResourceFilterAndSortTogether() throws {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)

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

        queryModel.searchText = "cdn"
        queryModel.activeFilters = [.image, .script]
        queryModel.sortDescriptors = [
            SortDescriptor(\.requestID, order: .reverse)
        ]

        #expect(queryModel.displayEntries.map(\.requestID) == [3, 2])

        queryModel.activeFilters = [.all]
        #expect(queryModel.effectiveFilters.isEmpty)
        #expect(queryModel.displayEntries.map(\.requestID) == [3, 2])
    }

    @Test
    func assigningEmptyActiveFiltersClearsEffectiveFilters() {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)

        queryModel.activeFilters = [.image, .script]
        #expect(queryModel.effectiveFilters == [.image, .script])

        queryModel.activeFilters = []
        #expect(queryModel.activeFilters.isEmpty)
        #expect(queryModel.effectiveFilters.isEmpty)
    }

    @Test
    func clearResetsSelectedEntry() throws {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)
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
        #expect(queryModel.displayEntries.isEmpty)
    }

    @Test
    func clearKeepsSearchAndResourceFiltersWhileResettingEntriesAndSelection() throws {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)
        try applyRequestStart(
            to: inspector,
            requestID: 31,
            url: "https://example.com/filter-target.js",
            initiator: "script",
            monotonicMs: 1_000
        )
        let selectedEntry = try #require(inspector.store.entries.first)
        inspector.selectEntry(selectedEntry)
        queryModel.searchText = "filter-target"
        queryModel.activeFilters = [.script]

        inspector.clear()

        #expect(inspector.selectedEntry == nil)
        #expect(inspector.store.entries.isEmpty)
        #expect(queryModel.displayEntries.isEmpty)
        #expect(queryModel.searchText == "filter-target")
        #expect(queryModel.activeFilters == [.script])
        #expect(queryModel.effectiveFilters == [.script])
    }

    @Test
    func displayEntriesKeepsBodylessBufferedStyleEntriesSearchableAndFilterable() throws {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)
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

        queryModel.searchText = "buffered-endpoint"
        queryModel.activeFilters = [.xhrFetch]

        let displayed = queryModel.displayEntries
        #expect(displayed.count == 1)
        let entry = try #require(displayed.first)
        #expect(entry.requestID == 21)
        #expect(entry.requestBody == nil)
        #expect(entry.responseBody == nil)
    }

    @Test
    func selectedEntryRemainsWhenFilterExcludesDisplayedEntries() throws {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)
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
        queryModel.activeFilters = [.stylesheet]

        #expect(queryModel.displayEntries.map(\.requestID) == [62])
        #expect(inspector.selectedEntry?.id == selectedEntry.id)
    }

    @Test
    func selectedEntryClearsWhenPrunedFromStoreByRetentionLimit() async throws {
        let inspector = WINetworkInspectorStore(
            session: WINetworkRuntime(configuration: .init(maxEntries: 1))
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

        #expect(inspector.selectedEntry == nil)
        #expect(inspector.store.entries.count == 1)
        #expect(inspector.store.entries.first?.requestID == 72)
        #expect(inspector.store.entries.first?.id != initiallySelectedID)
    }

    @Test
    func displayEntriesUpdatesWhenObservedEntryStateChanges() async throws {
        let inspector = WINetworkInspectorStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(inspector: inspector)
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
        let displayEntries = displayEntryRecorder(for: queryModel)
        inspector.store.applyEvent(responseReceived)

        _ = await displayEntries.next(where: { $0.first?.statusLabel == "404" })
        #expect(queryModel.displayEntries.first?.statusSeverity == .warning)
        #expect(queryModel.displayEntries.first?.fileTypeLabel == "json")
    }

    @Test
    func observeSearchTextSuppressesDuplicateConsecutiveStates() async {
        let queryModel = WINetworkQueryState(inspector: WINetworkInspectorStore(session: WINetworkRuntime()))
        let recorder = searchTextRecorder(for: queryModel)

        let initialValue = await recorder.next()
        #expect(initialValue == "")

        queryModel.searchText = "dup-keyword"
        let updatedValue = await recorder.next()
        #expect(updatedValue == "dup-keyword")

        queryModel.searchText = "dup-keyword"
        queryModel.searchText = "final-keyword"

        let nextValue = await recorder.next()
        #expect(nextValue == "final-keyword")
    }

    @Test
    func observeSearchTextStopsEmittingAfterCancel() async {
        let queryModel = WINetworkQueryState(inspector: WINetworkInspectorStore(session: WINetworkRuntime()))
        let emissions = AsyncValueQueue<String>()
        let handle = queryModel.observe(\.searchText, options: [.removeDuplicates]) { value in
            Task {
                await emissions.push(value)
            }
        }

        let initialValue = await emissions.next()
        #expect(initialValue == "")

        handle.cancel()

        queryModel.searchText = "after-cancel"
        queryModel.searchText = "after-cancel-2"
        let confirmation = searchTextRecorder(for: queryModel)
        let confirmedValue = await confirmation.next()
        #expect(confirmedValue == "after-cancel-2")

        #expect(await emissions.snapshot().isEmpty)
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

@MainActor
private func fetchStateRecorder(
    for body: NetworkBody
) -> ObservationRecorder<String> {
    let recorder = ObservationRecorder<String>()
    recorder.record { didChange in
        body.observe(\.fetchState, options: [.removeDuplicates]) { state in
            didChange(fetchStateLabel(state))
        }
    }
    return recorder
}

private func fetchStateLabel(_ state: NetworkBody.FetchState?) -> String {
    switch state {
    case .inline:
        "inline"
    case .fetching:
        "fetching"
    case .full:
        "full"
    case .failed(.unavailable):
        "failed:unavailable"
    case .failed(.decodeFailed):
        "failed:decodeFailed"
    case .failed(.unknown):
        "failed:unknown"
    case nil:
        "nil"
    }
}

@MainActor
private func searchTextRecorder(for queryModel: WINetworkQueryState) -> ObservationRecorder<String> {
    let recorder = ObservationRecorder<String>()
    recorder.record { didChange in
        return queryModel.observe(\.searchText, options: [.removeDuplicates]) { value in
            didChange(value)
        }
    }
    return recorder
}

private struct NetworkDisplayEntrySnapshot: Equatable, Sendable {
    let requestID: Int
    let statusLabel: String
    let fileTypeLabel: String
}

@MainActor
private func displayEntryRecorder(
    for queryModel: WINetworkQueryState
) -> ObservationRecorder<[NetworkDisplayEntrySnapshot]> {
    let recorder = ObservationRecorder<[NetworkDisplayEntrySnapshot]>()
    recorder.record { didChange in
        queryModel.observe(\.displayEntriesRevision, options: [.removeDuplicates]) { _ in
            didChange(
                queryModel.displayEntries.map {
                    NetworkDisplayEntrySnapshot(
                        requestID: $0.requestID,
                        statusLabel: $0.statusLabel,
                        fileTypeLabel: $0.fileTypeLabel
                    )
                }
            )
        }
    }
    return recorder
}

@MainActor
private final class StubNetworkBodyFetcher: NetworkBodyFetching {
    private let onFetch: @MainActor (String?, AnyObject?, NetworkBody.Role) async -> WINetworkBodyFetchResult
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

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        fetchRefs.append(ref)
        return await onFetch(ref, handle, role)
    }
}

import Foundation
import Testing
@testable import WebInspectorKitCore
@testable import WebInspectorKit

@MainActor
struct NetworkInspectorTests {
    @Test
    func applyFetchedBodyUpdatesDecodedBodyLengthForResponseBody() {
        let inspector = WebInspector.NetworkInspector(session: NetworkSession())
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

        inspector.applyFetchedBody(fetched, to: target, entry: entry)

        #expect(target.fetchState == .full)
        #expect(target.size == 13)
        #expect(entry.decodedBodyLength == 13)
    }

    @Test
    func applyFetchedBodyUpdatesRequestBodyBytesForRequestBody() {
        let inspector = WebInspector.NetworkInspector(session: NetworkSession())
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

        inspector.applyFetchedBody(fetched, to: target, entry: entry)

        #expect(target.fetchState == .full)
        #expect(target.size == 256)
        #expect(entry.requestBodyBytesSent == 256)
    }

    @Test
    func displayEntriesAppliesSearchResourceFilterAndSortTogether() throws {
        let inspector = WebInspector.NetworkInspector(session: NetworkSession())

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
    func setResourceFilterAllClearsSpecificSelection() {
        let inspector = WebInspector.NetworkInspector(session: NetworkSession())

        inspector.activeResourceFilters = [.image, .script]
        #expect(inspector.effectiveResourceFilters == [.image, .script])

        inspector.setResourceFilter(.all, isEnabled: true)
        #expect(inspector.activeResourceFilters.isEmpty)
        #expect(inspector.effectiveResourceFilters.isEmpty)
    }

    @Test
    func clearResetsSelectedEntryID() throws {
        let inspector = WebInspector.NetworkInspector(session: NetworkSession())
        try applyRequestStart(
            to: inspector,
            requestID: 11,
            url: "https://example.com/detail",
            initiator: "fetch",
            monotonicMs: 1_000
        )

        let selectedID = try #require(inspector.store.entries.first?.id)
        inspector.selectedEntryID = selectedID

        inspector.clear()

        #expect(inspector.selectedEntryID == nil)
        #expect(inspector.store.entries.isEmpty)
    }

    @Test
    func displayEntriesKeepsBodylessBufferedStyleEntriesSearchableAndFilterable() throws {
        let inspector = WebInspector.NetworkInspector(session: NetworkSession())
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

    private func applyRequestStart(
        to inspector: WebInspector.NetworkInspector,
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

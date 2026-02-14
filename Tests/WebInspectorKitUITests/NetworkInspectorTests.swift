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
}

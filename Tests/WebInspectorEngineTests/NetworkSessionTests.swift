import Testing
import WebKit
@testable import WebInspectorEngine

@MainActor
struct NetworkSessionTests {
    @Test
    func startsInActiveMode() {
        let session = NetworkSession()

        #expect(session.mode == .active)
    }

    @Test
    func requestBodyIfNeededFetchesInlineBodyWhenAttached() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                reference: ref,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let session = NetworkSession(bodyFetcher: fetcher)
        session.attach(pageWebView: WKWebView(frame: .zero))

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        session.requestBodyIfNeeded(for: entry, role: .response)

        let fetched = await waitUntil {
            body.fetchState == .full && body.full == "body"
        }
        #expect(fetched)
        #expect(fetcher.fetchRefs == ["resp_ref"])
    }

    @Test
    func requestBodyIfNeededSkipsWhenSessionIsDetached() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("fetchBody should not run while detached")
            return nil
        }
        let session = NetworkSession(bodyFetcher: fetcher)
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        session.requestBodyIfNeeded(for: entry, role: .response)

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(body.fetchState == .inline)
    }

    @Test
    func requestBodyIfNeededDoesNotRetryFailedBody() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in nil }
        let session = NetworkSession(bodyFetcher: fetcher)
        session.attach(pageWebView: WKWebView(frame: .zero))

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        session.requestBodyIfNeeded(for: entry, role: .response)

        let failed = await waitUntil {
            body.fetchState == .failed(.unavailable)
        }
        #expect(failed)
        #expect(fetcher.fetchRefs.count == 1)

        session.requestBodyIfNeeded(for: entry, role: .response)
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.count == 1)
    }

    @Test
    func requestBodyIfNeededSkipsNonInlineBodies() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("fetchBody should not run for non-inline bodies")
            return nil
        }
        let session = NetworkSession(bodyFetcher: fetcher)
        session.attach(pageWebView: WKWebView(frame: .zero))

        let entry = makeEntry()

        let fetchingBody = makeBody(reference: "fetching-ref", role: .response)
        fetchingBody.fetchState = .fetching
        entry.responseBody = fetchingBody
        session.requestBodyIfNeeded(for: entry, role: .response)

        let fullBody = makeBody(reference: "full-ref", role: .response)
        fullBody.fetchState = .full
        entry.responseBody = fullBody
        session.requestBodyIfNeeded(for: entry, role: .response)

        let failedBody = makeBody(reference: "failed-ref", role: .response)
        failedBody.fetchState = .failed(.unavailable)
        entry.responseBody = failedBody
        session.requestBodyIfNeeded(for: entry, role: .response)

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.isEmpty)
        #expect(fetchingBody.fetchState == .fetching)
        #expect(fullBody.fetchState == .full)
        #expect(failedBody.fetchState == .failed(.unavailable))
    }

    @Test
    func requestBodyIfNeededMarksUnavailableWhenReferenceAndHandleAreMissing() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("fetchBody should not run without reference or handle")
            return nil
        }
        let session = NetworkSession(bodyFetcher: fetcher)
        session.attach(pageWebView: WKWebView(frame: .zero))

        let entry = makeEntry()
        let body = NetworkBody(
            kind: .text,
            preview: "preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: nil,
            handle: nil,
            formEntries: [],
            fetchState: .inline,
            role: .response
        )
        entry.responseBody = body

        session.requestBodyIfNeeded(for: entry, role: .response)

        let failed = await waitUntil {
            body.fetchState == .failed(.unavailable)
        }
        #expect(failed)
        #expect(fetcher.fetchRefs.isEmpty)
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

    private func makeBody(reference: String, role: NetworkBody.Role) -> NetworkBody {
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

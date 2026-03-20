import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorEngine

@MainActor
struct NetworkSessionTests {
    @Test
    func startsInActiveMode() {
        let session = NetworkSession()

        #expect(session.mode == .active)
    }

    @Test
    func defaultSessionUsesFunctionalPageAgentBackend() {
        let session = NetworkSession()

        #expect(session.testBackendTypeName() == "NetworkPageAgent")
        #expect(session.backendSupport.isSupported)
    }

    @Test
    func attachReplacingWebViewPreservesExistingEntriesWhileActive() async throws {
        let session = NetworkSession()
        let firstWebView = WKWebView(frame: .zero)
        let secondWebView = WKWebView(frame: .zero)

        await session.attach(pageWebView: firstWebView)
        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 41,
            "url": "https://example.com/navigation",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 4_100.0, wallMs: 1_700_000_004_100.0)
        ])
        session.store.apply(start, sessionID: "")
        #expect(session.store.entries.count == 1)

        await session.attach(pageWebView: secondWebView)

        #expect(session.lastPageWebView === secondWebView)
        #expect(session.store.entries.count == 1)
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
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

        let fetched = await waitUntil {
            body.fetchState == .full && body.full == "body"
        }
        #expect(fetched)
        #expect(fetcher.fetchRefs == ["resp_ref"])
    }

    @Test
    func requestBodyIfNeededDiscardsInFlightFetchWhenLocatorChanges() async {
        let fetcher = StubNetworkBodyFetcher(onFetch: { ref, _, role in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return NetworkBody(
                kind: .text,
                preview: nil,
                full: "body-\(ref ?? "nil")",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                reference: ref,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        })
        let session = NetworkSession(bodyFetcher: fetcher)
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        let loadTask = Task<Void, Never> {
            _ = try? await session.loadBodyIfNeeded(for: entry, role: NetworkBody.Role.response)
        }
        await Task.yield()
        body.reference = "resp_ref_committed"
        await loadTask.value

        let reset = await waitUntil {
            body.fetchState == .inline
        }
        #expect(reset)
        #expect(body.full == nil)
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

        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

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
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

        let failed = await waitUntil {
            body.fetchState == .failed(.unavailable)
        }
        #expect(failed)
        #expect(fetcher.fetchRefs.count == 1)

        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchRefs.count == 1)
    }

    @Test
    func requestBodyIfNeededMarksUnavailableWhenBodyFetcherCannotRestoreAgent() async {
        let fetcher = StubNetworkBodyFetcher(resultOnFetch: { _, _, _ in
            .agentUnavailable
        })
        let session = NetworkSession(bodyFetcher: fetcher)
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

        let failed = await waitUntil {
            body.fetchState == .failed(.unavailable)
        }
        #expect(failed)
        #expect(fetcher.fetchRefs == ["resp_ref"])
    }

    @Test
    func cancelBodyFetchesResetsFetchingStateAndPreventsApply() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return NetworkBody(
                kind: .text,
                preview: nil,
                full: "late-\(ref ?? "nil")",
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
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        let loadTask = Task<Void, Never> {
            _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)
        }

        let started = await waitUntil {
            body.fetchState == .fetching
        }
        #expect(started)

        loadTask.cancel()
        await loadTask.value
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(body.fetchState == .inline)
        #expect(body.full == nil)
    }

    @Test
    func requestBodyIfNeededLeavesBodyInlineWhenLocatorChangesWithoutCancellation() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return NetworkBody(
                kind: .text,
                preview: nil,
                full: "late-\(ref ?? "nil")",
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
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        let loadTask = Task<Void, Never> {
            _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)
        }

        let started = await waitUntil {
            body.fetchState == .fetching && fetcher.fetchRefs == ["resp_ref"]
        }
        #expect(started)

        body.reference = "resp_ref_committed"
        await loadTask.value

        let reset = await waitUntil {
            body.fetchState == .inline
        }
        #expect(reset)
        #expect(body.full == nil)
        #expect(fetcher.fetchRefs == ["resp_ref"])
    }

    @Test
    func requestBodyIfNeededSkipsNonInlineBodies() async {
        let fetcher = StubNetworkBodyFetcher { _, _, _ in
            Issue.record("fetchBody should not run for non-inline bodies")
            return nil
        }
        let session = NetworkSession(bodyFetcher: fetcher)
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

        let entry = makeEntry()

        let fetchingBody = makeBody(reference: "fetching-ref", role: .response)
        fetchingBody.fetchState = .fetching
        entry.responseBody = fetchingBody
        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

        let fullBody = makeBody(reference: "full-ref", role: .response)
        fullBody.fetchState = .full
        entry.responseBody = fullBody
        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

        let failedBody = makeBody(reference: "failed-ref", role: .response)
        failedBody.fetchState = .failed(.unavailable)
        entry.responseBody = failedBody
        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

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
        let webView = WKWebView(frame: .zero)
        await session.attach(pageWebView: webView)

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

        _ = try? await session.loadBodyIfNeeded(for: entry, role: .response)

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

    init(
        resultOnFetch: @escaping @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBodyFetchResult
    ) {
        self.onFetch = resultOnFetch
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

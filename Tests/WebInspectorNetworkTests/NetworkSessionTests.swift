import Testing
import ObservationBridge
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorCore
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
struct NetworkSessionTests {
    @Test
    func sessionCanUseInjectedPageDriver() {
        let pageAgent = StubNetworkPageDriver()
        let session = WINetworkRuntime(
            configuration: .init(),
            backend: pageAgent
        )
        let webView = makeIsolatedTestWebView()

        session.attach(pageWebView: webView)
        session.setMode(.buffering)
        session.clearNetworkLogs()

        #expect(session.store === pageAgent.store)
        #expect(pageAgent.attachedWebViews.count == 1)
        #expect(pageAgent.attachedWebViews.first === webView)
        #expect(pageAgent.observedModes == [.active, .buffering])
        #expect(pageAgent.clearCount == 1)
    }

    @Test
    func unavailableSessionDoesNotFallbackToLegacyNetworkBridge() async {
        let session = WINetworkRuntime(configuration: .init())
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        #expect(session.backendSupport.isSupported == false)
        #expect(session.testPageAgentTypeName() == "WINetworkUnavailableBackend")
        #expect(session.transportCapabilities.isEmpty)

        let body = await session.fetchBody(locator: .networkRequest(id: "request-1", targetIdentifier: nil), role: .response)
        #expect(body == nil)
    }

    @Test
    func macOSNativeTransportUsesTransportDriver() {
        let session = WINetworkRuntime(
            configuration: .init(),
            defaultTransportSupportSnapshot: .supported(
                backendKind: .macOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .networkDomain]
            )
        )

        #expect(session.testPageAgentTypeName() == "NetworkTransportDriver")
    }

    @Test
    func startsInActiveMode() {
        let session = WINetworkRuntime()

        #expect(session.mode == .active)
    }

    @Test
    func requestBodyIfNeededFetchesInlineBodyWhenAttached() async {
        let fetcher = StubNetworkBodyFetcher { locator, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body
        let states = fetchStateRecorder(for: body)

        session.requestBodyIfNeeded(for: entry, role: .response)

        let fetched = await states.next(where: { $0 == "full" })
        #expect(fetched == "full")
        #expect(body.full == "body")
        #expect(fetcher.fetchRequestIDs == ["resp_ref"])
    }

    @Test
    func requestBodyIfNeededRereadsDeferredLocatorBeforeDispatchingFetch() async {
        let fetcher = StubNetworkBodyFetcher { _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "request-body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = NetworkBody(
            kind: .text,
            preview: "request-preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            deferredLocator: .networkRequest(id: "request-ref", targetIdentifier: "page-provisional"),
            formEntries: [],
            fetchState: .inline,
            role: .request
        )
        entry.requestBody = body
        let states = fetchStateRecorder(for: body)

        session.requestBodyIfNeeded(for: entry, role: .request)
        body.rebindDeferredTarget(from: "page-provisional", to: "page-committed")

        let fetched = await states.next(where: { $0 == "full" })
        #expect(fetched == "full")
        #expect(fetcher.fetchRequestIDs == ["request-ref"])
        #expect(fetcher.fetchTargetIdentifiers == ["page-committed"])
    }

    @Test
    func requestBodyIfNeededSkipsWhenSessionIsDetached() async {
        let fetcher = StubNetworkBodyFetcher { _, _ in
            Issue.record("fetchBody should not run while detached")
            return nil
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body

        session.requestBodyIfNeeded(for: entry, role: .response)

        #expect(fetcher.fetchRequestIDs.isEmpty)
        #expect(body.fetchState == .inline)
    }

    @Test
    func requestBodyIfNeededDoesNotRetryFailedBody() async {
        let fetcher = StubNetworkBodyFetcher { _, _ in nil }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body
        let states = fetchStateRecorder(for: body)

        session.requestBodyIfNeeded(for: entry, role: .response)

        let failed = await states.next(where: { $0 == "failed:unavailable" })
        #expect(failed == "failed:unavailable")
        #expect(fetcher.fetchRequestIDs.count == 1)

        session.requestBodyIfNeeded(for: entry, role: .response)

        #expect(fetcher.fetchRequestIDs.count == 1)
    }

    @Test
    func requestBodyIfNeededMarksUnavailableWhenBodyFetcherCannotRestoreAgent() async {
        let fetcher = StubNetworkBodyFetcher(resultOnFetch: { _, _ in
            .agentUnavailable
        })
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body
        let states = fetchStateRecorder(for: body)

        session.requestBodyIfNeeded(for: entry, role: .response)

        let failed = await states.next(where: { $0 == "failed:unavailable" })
        #expect(failed == "failed:unavailable")
        #expect(fetcher.fetchRequestIDs == ["resp_ref"])
    }

    @Test
    func cancelBodyFetchesResetsFetchingStateAndPreventsApply() async {
        let fetchStarted = AsyncGate()
        let releaseFetch = AsyncGate()
        let fetchFinished = AsyncGate()
        let fetcher = StubNetworkBodyFetcher { _, role in
            await fetchStarted.open()
            await releaseFetch.wait()
            defer {
                Task {
                    await fetchFinished.open()
                }
            }
            return NetworkBody(
                kind: .text,
                preview: nil,
                full: "late-body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = body
        let states = fetchStateRecorder(for: body)

        session.requestBodyIfNeeded(for: entry, role: .response)

        let started = await states.next(where: { $0 == "fetching" })
        #expect(started == "fetching")
        await fetchStarted.wait()

        session.cancelBodyFetches(for: entry)
        await releaseFetch.open()
        await fetchFinished.wait()

        #expect(body.fetchState == .inline)
        #expect(body.full == nil)
    }

    @Test
    func requestBodyIfNeededIgnoresLateFetchForReplacedBody() async {
        let fetchStarted = AsyncGate()
        let releaseFetch = AsyncGate()
        let fetchFinished = AsyncGate()
        let fetcher = StubNetworkBodyFetcher { _, role in
            await fetchStarted.open()
            await releaseFetch.wait()
            defer {
                Task {
                    await fetchFinished.open()
                }
            }
            return NetworkBody(
                kind: .text,
                preview: nil,
                full: "late-body",
                size: 9,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let originalBody = makeBody(reference: "resp_ref", role: .response)
        entry.responseBody = originalBody
        let states = fetchStateRecorder(for: originalBody)

        session.requestBodyIfNeeded(for: entry, role: .response)

        let started = await states.next(where: { $0 == "fetching" })
        #expect(started == "fetching")
        await fetchStarted.wait()

        let replacementBody = makeBody(reference: "replacement-ref", role: .response)
        entry.responseBody = replacementBody

        await releaseFetch.open()
        await fetchFinished.wait()

        #expect(entry.responseBody === replacementBody)
        #expect(replacementBody.fetchState == .inline)
        #expect(replacementBody.full == nil)
        #expect(entry.decodedBodyLength == nil)
        #expect(originalBody.full == nil)
    }

    @Test
    func requestBodyIfNeededSkipsNonInlineBodies() async {
        let fetcher = StubNetworkBodyFetcher { _, _ in
            Issue.record("fetchBody should not run for non-inline bodies")
            return nil
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

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

        #expect(fetcher.fetchRequestIDs.isEmpty)
        #expect(fetchingBody.fetchState == .fetching)
        #expect(fullBody.fetchState == .full)
        #expect(failedBody.fetchState == .failed(.unavailable))
    }

    @Test
    func requestBodyIfNeededMarksUnavailableWhenReferenceAndHandleAreMissing() async {
        let fetcher = StubNetworkBodyFetcher { _, _ in
            Issue.record("fetchBody should not run without reference or handle")
            return nil
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = NetworkBody(
            kind: .text,
            preview: "preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            deferredLocator: nil,
            formEntries: [],
            fetchState: .inline,
            role: .response
        )
        entry.responseBody = body
        let states = fetchStateRecorder(for: body)

        session.requestBodyIfNeeded(for: entry, role: .response)

        let failed = await states.next(where: { $0 == "failed:unavailable" })
        #expect(failed == "failed:unavailable")
        #expect(fetcher.fetchRequestIDs.isEmpty)
    }

    @Test
    func requestBodyIfNeededKeepsInlinePreviewWhenDeferredRequestLoadingIsUnsupported() async {
        let fetcher = StubNetworkBodyFetcher(
            supportedRoles: [.response]
        ) { _, _ in
            Issue.record("fetchBody should not run for unsupported request-body loading")
            return nil
        }
        let session = WINetworkRuntime(bodyFetcher: fetcher)
        let webView = makeIsolatedTestWebView()
        session.attach(pageWebView: webView)

        let entry = makeEntry()
        let body = NetworkBody(
            kind: .text,
            preview: "request-preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            deferredLocator: nil,
            formEntries: [],
            fetchState: .inline,
            role: .request
        )
        entry.requestBody = body

        session.requestBodyIfNeeded(for: entry, role: .request)

        #expect(fetcher.fetchRequestIDs.isEmpty)
        #expect(body.fetchState == .inline)
        #expect(body.preview == "request-preview")
        #expect(body.full == nil)
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
            deferredLocator: .networkRequest(id: reference, targetIdentifier: nil),
            formEntries: [],
            fetchState: .inline,
            role: role
        )
    }

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
}

@MainActor
private final class StubNetworkBodyFetcher: NetworkBodyFetching {
    private let onFetch: @MainActor (NetworkDeferredBodyLocator, NetworkBody.Role) async -> WINetworkBodyFetchResult
    private let supportedRoles: Set<NetworkBody.Role>
    private(set) var fetchRequestIDs: [String?] = []
    private(set) var fetchTargetIdentifiers: [String?] = []

    init(
        supportedRoles: Set<NetworkBody.Role> = Set(NetworkBody.Role.allCases),
        onFetch: @escaping @MainActor (NetworkDeferredBodyLocator, NetworkBody.Role) async -> NetworkBody?
    ) {
        self.supportedRoles = supportedRoles
        self.onFetch = { locator, role in
            guard let body = await onFetch(locator, role) else {
                return .bodyUnavailable
            }
            return .fetched(body)
        }
    }

    init(
        supportedRoles: Set<NetworkBody.Role> = Set(NetworkBody.Role.allCases),
        resultOnFetch: @escaping @MainActor (NetworkDeferredBodyLocator, NetworkBody.Role) async -> WINetworkBodyFetchResult
    ) {
        self.supportedRoles = supportedRoles
        self.onFetch = resultOnFetch
    }

    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        supportedRoles.contains(role)
    }

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        fetchRequestIDs.append(locator.requestID)
        fetchTargetIdentifiers.append(locator.targetIdentifier)
        return await onFetch(locator, role)
    }
}

@MainActor
private final class StubNetworkPageDriver: WINetworkBackend {
    private(set) weak var webView: WKWebView?
    let store = NetworkStore()
    let support = WIBackendSupport(
        availability: .unsupported,
        backendKind: .unsupported,
        failureReason: "stub"
    )
    private(set) var observedModes: [NetworkLoggingMode] = []
    private(set) var attachedWebViews: [WKWebView] = []
    private(set) var clearCount = 0

    func setMode(_ mode: NetworkLoggingMode) {
        observedModes.append(mode)
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
        if let newWebView {
            attachedWebViews.append(newWebView)
        }
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        webView = nil
    }

    func clearNetworkLogs() {
        clearCount += 1
    }

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        _ = locator
        _ = role
        return .bodyUnavailable
    }
}

private extension NetworkDeferredBodyLocator {
    var requestID: String? {
        switch self {
        case .networkRequest(let requestID, _):
            requestID
        case .pageResource, .opaqueHandle:
            nil
        }
    }

    var targetIdentifier: String? {
        switch self {
        case .networkRequest(_, let targetIdentifier):
            targetIdentifier
        case .pageResource(let targetIdentifier, _, _):
            targetIdentifier
        case .opaqueHandle:
            nil
        }
    }
}

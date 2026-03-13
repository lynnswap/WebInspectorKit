import Foundation
import WebKit

@MainActor
package final class WINetworkRuntime {
    private struct BodyFetchKey: Hashable {
        let entryID: UUID
        let role: NetworkBody.Role
    }

    package var configuration: NetworkConfiguration {
        didSet {
            store.maxEntries = configuration.maxEntries
        }
    }

    package private(set) var mode: NetworkLoggingMode = .active
    package let store: NetworkStore
    package private(set) weak var lastPageWebView: WKWebView?

    private let backend: any WINetworkBackend
    private var bodyFetchTasks: [BodyFetchKey: (token: UUID, task: Task<Void, Never>)] = [:]

    package init(
        configuration: NetworkConfiguration = .init(),
        backend: any WINetworkBackend
    ) {
        self.configuration = configuration
        self.backend = backend
        self.store = backend.store
        self.store.maxEntries = configuration.maxEntries
    }

    package convenience init(configuration: NetworkConfiguration = .init()) {
        self.init(
            configuration: configuration,
            backend: WINetworkUnavailableBackend()
        )
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        bodyFetcher: any NetworkBodyFetching
    ) {
        self.init(
            configuration: configuration,
            backend: WINetworkBodyFetchingBackend(bodyFetcher: bodyFetcher)
        )
    }

    package var hasAttachedPageWebView: Bool {
        backend.webView != nil
    }

    package var backendSupport: WIBackendSupport {
        backend.support
    }

    package var transportCapabilities: Set<WIBackendCapability> {
        backend.support.capabilities
    }

    package func attach(pageWebView webView: WKWebView) {
        backend.setMode(mode)
        backend.attachPageWebView(webView)
        lastPageWebView = webView
    }

    package func suspend() {
        cancelAllBodyFetches()
        mode = .stopped
        backend.detachPageWebView(preparing: .stopped)
    }

    package func detach() {
        cancelAllBodyFetches()
        mode = .stopped
        backend.detachPageWebView(preparing: .stopped)
        lastPageWebView = nil
    }

    package func setMode(_ mode: NetworkLoggingMode) {
        self.mode = mode
        backend.setMode(mode)
    }

    package func clearNetworkLogs() {
        cancelAllBodyFetches()
        backend.clearNetworkLogs()
    }

    package func cancelBodyFetches(for entry: NetworkEntry) {
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .request), entry: entry)
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .response), entry: entry)
    }

    package func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        switch await backend.fetchBodyResult(ref: ref, handle: handle, role: role) {
        case .fetched(let body):
            return body
        case .agentUnavailable, .bodyUnavailable:
            return nil
        }
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        guard hasAttachedPageWebView else {
            return
        }
        guard let body = body(for: entry, role: role) else {
            return
        }
        guard shouldFetch(body) else {
            return
        }
        guard backend.supportsDeferredLoading(for: role) else {
            return
        }

        let bodyRef = body.reference
        let bodyHandle = body.handle
        let hasReference = bodyRef?.isEmpty == false
        let hasHandle = bodyHandle != nil
        guard hasReference || hasHandle else {
            body.markFailed(.unavailable)
            return
        }

        let key = BodyFetchKey(entryID: entry.id, role: role)
        body.markFetching()
        let token = UUID()
        let task = Task { @MainActor [weak self, weak entry, weak body] in
            defer {
                self?.clearBodyFetchTask(for: key, token: token)
            }
            guard let self, let entry, let body else {
                return
            }

            let fetchResult = await backend.fetchBodyResult(ref: bodyRef, handle: bodyHandle, role: role)

            guard !Task.isCancelled else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }

            guard self.body(for: entry, role: role) === body else {
                return
            }
            guard self.hasAttachedPageWebView else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }

            switch fetchResult {
            case .fetched(let fetched):
                entry.applyFetchedBody(fetched, to: body)
            case .agentUnavailable, .bodyUnavailable:
                body.markFailed(.unavailable)
            }
        }
        bodyFetchTasks[key] = (token, task)
    }

    package func prepareForNavigationReconnect() {
        cancelAllBodyFetches()
        backend.prepareForNavigationReconnect()
    }

    package func resumeAfterNavigationReconnect(to webView: WKWebView) {
        lastPageWebView = webView
        backend.resumeAfterNavigationReconnect()
    }
}

#if DEBUG
extension WINetworkRuntime {
    func wiApplyPreviewBatch(_ payload: NSDictionary) {
        guard let batch = NetworkEventBatch.decode(from: payload) else {
            return
        }
        store.applyNetworkBatch(batch)
    }
}

extension WINetworkRuntime {
    package func testBackendTypeName() -> String {
        String(describing: type(of: backend))
    }

    package func testPageAgentTypeName() -> String {
        testBackendTypeName()
    }
}
#endif

private extension WINetworkRuntime {
    func cancelAllBodyFetches() {
        let activeKeys = Array(bodyFetchTasks.keys)
        for key in activeKeys {
            cancelBodyFetch(for: key, entry: entry(forID: key.entryID))
        }
    }

    private func cancelBodyFetch(for key: BodyFetchKey, entry: NetworkEntry?) {
        if let activeTask = bodyFetchTasks.removeValue(forKey: key) {
            activeTask.task.cancel()
        }
        guard let entry else {
            return
        }
        resetBodyToInlineIfFetching(for: entry, role: key.role)
    }

    private func clearBodyFetchTask(for key: BodyFetchKey, token: UUID) {
        guard bodyFetchTasks[key]?.token == token else {
            return
        }
        bodyFetchTasks.removeValue(forKey: key)
    }

    func resetBodyToInlineIfFetching(
        for entry: NetworkEntry,
        role: NetworkBody.Role,
        expectedBody: NetworkBody? = nil
    ) {
        guard let currentBody = body(for: entry, role: role) else {
            return
        }
        if let expectedBody, currentBody !== expectedBody {
            return
        }
        if case .fetching = currentBody.fetchState {
            currentBody.fetchState = .inline
        }
    }

    func entry(forID id: UUID) -> NetworkEntry? {
        store.entries.first { $0.id == id }
    }

    func shouldFetch(_ body: NetworkBody) -> Bool {
        switch body.fetchState {
        case .inline:
            return true
        case .fetching, .full, .failed:
            return false
        }
    }

    func body(for entry: NetworkEntry, role: NetworkBody.Role) -> NetworkBody? {
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }
}

@MainActor
private final class WINetworkUnavailableBackend: WINetworkBackend {
    weak var webView: WKWebView?
    let store = NetworkStore()

    let support = WIBackendSupport(
        availability: .unsupported,
        backendKind: .unsupported,
        failureReason: "No backend was provided."
    )

    func setMode(_ mode: NetworkLoggingMode) {
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            store.reset()
        }
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        _ = modeBeforeDetach
        webView = nil
    }

    func clearNetworkLogs() {
        store.clear()
    }

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        _ = ref
        _ = handle
        _ = role
        return .agentUnavailable
    }
}

@MainActor
private final class WINetworkBodyFetchingBackend: WINetworkBackend {
    weak var webView: WKWebView?
    let store = NetworkStore()
    let support = WIBackendSupport(
        availability: .unsupported,
        backendKind: .unsupported,
        failureReason: "Test body fetch backend."
    )

    private let bodyFetcher: any NetworkBodyFetching

    init(bodyFetcher: any NetworkBodyFetching) {
        self.bodyFetcher = bodyFetcher
    }

    func setMode(_ mode: NetworkLoggingMode) {
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            store.reset()
        }
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        _ = modeBeforeDetach
        webView = nil
    }

    func clearNetworkLogs() {
        store.clear()
    }

    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        bodyFetcher.supportsDeferredLoading(for: role)
    }

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        await bodyFetcher.fetchBodyResult(ref: ref, handle: handle, role: role)
    }
}

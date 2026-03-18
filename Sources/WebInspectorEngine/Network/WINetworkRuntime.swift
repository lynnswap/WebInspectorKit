import Foundation
import WebKit

@MainActor
package final class WINetworkRuntime {
    package var configuration: NetworkConfiguration {
        didSet {
            store.maxEntries = configuration.maxEntries
        }
    }

    package private(set) var mode: NetworkLoggingMode = .active
    package let store: NetworkStore
    package private(set) weak var lastPageWebView: WKWebView?

    private let backend: any WINetworkBackend
    private lazy var bodyLoader = NetworkBodyLoader(
        bodyFetcher: backend,
        hasAttachedPageWebView: { [weak self] in
            self?.hasAttachedPageWebView ?? false
        },
        entryLookup: { [weak self] id in
            self?.entry(forID: id)
        },
        bodyLookup: { [weak self] entry, role in
            self?.body(for: entry, role: role)
        }
    )

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
            backend: NetworkPageAgent()
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
        if let currentWebView = backend.webView, currentWebView !== webView {
            backend.detachPageWebView(preparing: mode)
        }
        backend.setMode(mode)
        backend.attachPageWebView(webView)
        lastPageWebView = webView
    }

    package func suspend() {
        bodyLoader.cancelAll()
        mode = .stopped
        backend.setMode(.stopped)
        backend.detachPageWebView(preparing: .stopped)
    }

    package func detach() {
        bodyLoader.cancelAll()
        mode = .stopped
        backend.setMode(.stopped)
        backend.detachPageWebView(preparing: .stopped)
        lastPageWebView = nil
    }

    package func setMode(_ mode: NetworkLoggingMode) {
        self.mode = mode
        backend.setMode(mode)
    }

    package func clearNetworkLogs() {
        bodyLoader.cancelAll()
        backend.clearNetworkLogs()
    }

    package func cancelBodyFetches(for entry: NetworkEntry) {
        bodyLoader.cancelBodyFetches(for: entry)
    }

    package func fetchBody(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> NetworkBody? {
        switch await backend.fetchBodyResult(locator: locator, role: role) {
        case .fetched(let body):
            return body
        case .agentUnavailable, .bodyUnavailable:
            return nil
        }
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        bodyLoader.requestBodyIfNeeded(for: entry, role: role)
    }

    package func prepareForNavigationReconnect() {
        bodyLoader.cancelAll()
        backend.prepareForNavigationReconnect()
    }

    package func resumeAfterNavigationReconnect(to webView: WKWebView) {
        lastPageWebView = webView
        backend.resumeAfterNavigationReconnect(to: webView)
    }
}

#if DEBUG
extension WINetworkRuntime {
    func wiApplyPreviewBatch(_ payload: NSDictionary) {
        guard let batch = NetworkWire.PageHook.Batch.decode(from: payload) else {
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
    func entry(forID id: UUID) -> NetworkEntry? {
        store.entries.first { $0.id == id }
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

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        _ = locator
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

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        await bodyFetcher.fetchBodyResult(locator: locator, role: role)
    }
}

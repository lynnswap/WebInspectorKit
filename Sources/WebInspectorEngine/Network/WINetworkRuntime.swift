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
            backend: WINetworkUnsupportedBackend(reason: "No native network backend was provided.")
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

    package func attach(pageWebView webView: WKWebView) async {
        if let currentWebView = backend.webView, currentWebView !== webView {
            await backend.detachPageWebView(preparing: mode)
        }
        await backend.setMode(mode)
        await backend.attachPageWebView(webView)
        lastPageWebView = webView
    }

    package func suspend() async {
        mode = .stopped
        await backend.setMode(.stopped)
        await backend.detachPageWebView(preparing: .stopped)
    }

    package func detach() async {
        mode = .stopped
        await backend.setMode(.stopped)
        await backend.detachPageWebView(preparing: .stopped)
        lastPageWebView = nil
    }

    package func setMode(_ mode: NetworkLoggingMode) async {
        self.mode = mode
        await backend.setMode(mode)
    }

    package func clearNetworkLogs() async {
        await backend.clearNetworkLogs()
    }

    package func fetchBody(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> NetworkBody? {
        switch await backend.fetchBodyResult(locator: locator, role: role) {
        case .fetched(let body):
            return body
        case .agentUnavailable, .bodyUnavailable:
            return nil
        }
    }

    package func loadBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) async throws -> NetworkBody {
        guard let body = body(for: entry, role: role) else {
            throw WINetworkBodyLoadError.bodyUnavailable
        }
        return try await loadBodyIfNeeded(for: entry, body: body)
    }

    package func loadBodyIfNeeded(for entry: NetworkEntry, body: NetworkBody) async throws -> NetworkBody {
        return try await backend.loadBodyIfNeeded(for: entry, body: body)
    }

    package func prepareForNavigationReconnect() {
        backend.prepareForNavigationReconnect()
    }

    package func resumeAfterNavigationReconnect(to webView: WKWebView) {
        lastPageWebView = webView
        backend.resumeAfterNavigationReconnect(to: webView)
    }

    package func tearDownForDeinit() {
        mode = .stopped
        backend.tearDownForDeinit()
        lastPageWebView = nil
    }
}

#if DEBUG
extension WINetworkRuntime {
    package func testBackendTypeName() -> String {
        String(describing: type(of: backend))
    }
}
#endif

private extension WINetworkRuntime {
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
package final class WINetworkUnsupportedBackend: WINetworkBackend {
    package var webView: WKWebView? {
        nil
    }

    package let store = NetworkStore()
    package let isSupported = false
    package let failureReason: String?

    package init(reason: String = "Network backend is unsupported.") {
        self.failureReason = reason
    }

    package func setMode(_ mode: NetworkLoggingMode) async {
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            store.reset()
        }
    }

    package func attachPageWebView(_ newWebView: WKWebView?) async {
    }

    package func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) async {
        if let modeBeforeDetach {
            store.setRecording(modeBeforeDetach != .stopped)
            if modeBeforeDetach == .stopped {
                store.reset()
            }
        }
    }

    package func clearNetworkLogs() async {
        store.clear()
    }

    package func tearDownForDeinit() {
        store.setRecording(false)
        store.reset()
    }

    package func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        false
    }

    package func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        return .agentUnavailable
    }
}

@MainActor
private final class WINetworkBodyFetchingBackend: WINetworkBackend {
    weak var webView: WKWebView?
    let store = NetworkStore()
    let isSupported = false
    let failureReason: String? = "Test body fetch backend."

    private let bodyFetcher: any NetworkBodyFetching

    init(bodyFetcher: any NetworkBodyFetching) {
        self.bodyFetcher = bodyFetcher
    }

    func setMode(_ mode: NetworkLoggingMode) async {
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            store.reset()
        }
    }

    func attachPageWebView(_ newWebView: WKWebView?) async {
        webView = newWebView
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) async {
        webView = nil
    }

    func clearNetworkLogs() async {
        store.clear()
    }

    func tearDownForDeinit() {
        webView = nil
        store.setRecording(false)
        store.reset()
    }

    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        bodyFetcher.supportsDeferredLoading(for: role)
    }

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        await bodyFetcher.fetchBodyResult(locator: locator, role: role)
    }
}

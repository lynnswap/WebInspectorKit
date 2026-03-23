import Foundation
import WebKit

package typealias NetworkBodyFetchResult = WINetworkBodyFetchResult

@MainActor
public final class NetworkSession: PageSession {
    public typealias AttachmentResult = Void

    private let runtime: WINetworkRuntime

    public var configuration: NetworkConfiguration {
        get { runtime.configuration }
        set { runtime.configuration = newValue }
    }

    public var mode: NetworkLoggingMode {
        runtime.mode
    }

    public var store: NetworkStore {
        runtime.store
    }

    public private(set) weak var lastPageWebView: WKWebView?

    package var hasAttachedPageWebView: Bool {
        runtime.hasAttachedPageWebView
    }

    package var backendSupport: WIBackendSupport {
        runtime.backendSupport
    }

    package var transportCapabilities: Set<WIBackendCapability> {
        runtime.transportCapabilities
    }

    package var onPrepareForNavigationReconnect: (@MainActor () -> Void)?

    public convenience init(configuration: NetworkConfiguration = .init()) {
        self.init(runtime: WINetworkRuntime(configuration: configuration))
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        backend: any WINetworkBackend
    ) {
        self.init(runtime: WINetworkRuntime(configuration: configuration, backend: backend))
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        bodyFetcher: any NetworkBodyFetching
    ) {
        self.init(runtime: WINetworkRuntime(configuration: configuration, bodyFetcher: bodyFetcher))
    }

    package init(runtime: WINetworkRuntime) {
        self.runtime = runtime
        self.lastPageWebView = runtime.lastPageWebView
    }

    public func attach(pageWebView webView: WKWebView) async {
        await runtime.attach(pageWebView: webView)
        lastPageWebView = runtime.lastPageWebView
    }

    public func suspend() async {
        await runtime.suspend()
        lastPageWebView = runtime.lastPageWebView
    }

    public func detach() async {
        await runtime.detach()
        lastPageWebView = runtime.lastPageWebView
    }

    public func setMode(_ mode: NetworkLoggingMode) async {
        await runtime.setMode(mode)
    }

    public func clearNetworkLogs() async {
        await runtime.clearNetworkLogs()
    }

    public func fetchBody(
        ref: String?,
        handle: AnyObject?,
        role: NetworkBody.Role
    ) async -> NetworkBody? {
        guard let locator = NetworkBody.makeDeferredLocator(reference: ref, handle: handle) else {
            return nil
        }
        return await runtime.fetchBody(locator: locator, role: role)
    }

    package func fetchBody(
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> NetworkBody? {
        await runtime.fetchBody(locator: locator, role: role)
    }

    package func loadBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) async throws -> NetworkBody {
        try await runtime.loadBodyIfNeeded(for: entry, role: role)
    }

    package func loadBodyIfNeeded(for entry: NetworkEntry, body: NetworkBody) async throws -> NetworkBody {
        try await runtime.loadBodyIfNeeded(for: entry, body: body)
    }

    package func prepareForNavigationReconnect() {
        onPrepareForNavigationReconnect?()
        runtime.prepareForNavigationReconnect()
    }

    package func resumeAfterNavigationReconnect(to webView: WKWebView) {
        runtime.resumeAfterNavigationReconnect(to: webView)
        lastPageWebView = runtime.lastPageWebView
    }

    package func tearDownForDeinit() {
        runtime.tearDownForDeinit()
        lastPageWebView = runtime.lastPageWebView
    }
}

#if DEBUG
extension NetworkSession {
    package func testBackendTypeName() -> String {
        runtime.testBackendTypeName()
    }

    package func testPageAgentTypeName() -> String {
        runtime.testPageAgentTypeName()
    }
}
#endif

import WebKit

@MainActor
public final class NetworkSession: PageSession {
    public typealias AttachmentResult = Void

    public var configuration: NetworkConfiguration {
        didSet {
            store.maxEntries = configuration.maxEntries
        }
    }

    private(set) var mode: NetworkLoggingMode = .buffering

    public let store: NetworkStore
    public private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: NetworkPageAgent

    public init(configuration: NetworkConfiguration = .init()) {
        self.configuration = configuration
        let pageAgent = NetworkPageAgent()
        self.pageAgent = pageAgent
        self.store = pageAgent.store
        self.store.maxEntries = configuration.maxEntries
    }

    public func attach(pageWebView webView: WKWebView) {
        pageAgent.attachPageWebView(webView)
        lastPageWebView = webView
    }

    public func suspend() {
        mode = .buffering
        pageAgent.detachPageWebView(preparing: .buffering)
    }

    public func detach() {
        mode = .stopped
        pageAgent.detachPageWebView(preparing: .stopped)
        lastPageWebView = nil
    }

    public func setMode(_ mode: NetworkLoggingMode) {
        self.mode = mode
        pageAgent.setMode(mode)
    }

    public func clearNetworkLogs() {
        pageAgent.clearNetworkLogs()
    }

    public func fetchBody(ref: String, role: NetworkBody.Role) async -> NetworkBody? {
        await pageAgent.fetchBody(bodyRef: ref, role: role)
    }
}

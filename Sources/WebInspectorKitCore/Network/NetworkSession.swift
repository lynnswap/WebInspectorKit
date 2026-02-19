import WebKit

@MainActor
public final class NetworkSession: PageSession {
    public typealias AttachmentResult = Void

    public var configuration: NetworkConfiguration {
        didSet {
            store.maxEntries = configuration.maxEntries
        }
    }

    private(set) var mode: NetworkLoggingMode = .active

    public let store: NetworkStore
    public private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: NetworkPageAgent

    var hasAttachedPageWebView: Bool {
        pageAgent.webView != nil
    }

    public init(configuration: NetworkConfiguration = .init()) {
        self.configuration = configuration
        let pageAgent = NetworkPageAgent()
        self.pageAgent = pageAgent
        self.store = pageAgent.store
        self.store.maxEntries = configuration.maxEntries
    }

    public func attach(pageWebView webView: WKWebView) {
        pageAgent.setMode(mode)
        pageAgent.attachPageWebView(webView)
        lastPageWebView = webView
    }

    public func suspend() {
        mode = .stopped
        pageAgent.detachPageWebView(preparing: .stopped)
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

    public func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        await pageAgent.fetchBody(bodyRef: ref, bodyHandle: handle, role: role)
    }
}

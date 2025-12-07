import WebKit

@MainActor
public final class WINetworkSession: WIPageSession {
    public typealias AttachmentResult = Void

    public let store: WINetworkStore
    public private(set) weak var lastPageWebView: WKWebView?
    private let networkAgent: WINetworkPageAgent

    public init() {
        let networkAgent = WINetworkPageAgent()
        self.networkAgent = networkAgent
        self.store = networkAgent.store
    }

    public func attach(pageWebView webView: WKWebView) {
        networkAgent.attachPageWebView(webView)
        lastPageWebView = webView
    }

    public func suspend() {
        networkAgent.detachPageWebView(disableNetworkLogging: true)
    }

    public func detach() {
        suspend()
        lastPageWebView = nil
    }

    public func setRecording(_ enabled: Bool) {
        networkAgent.setRecording(enabled)
    }

    public func clearNetworkLogs() {
        networkAgent.clearNetworkLogs()
    }
}

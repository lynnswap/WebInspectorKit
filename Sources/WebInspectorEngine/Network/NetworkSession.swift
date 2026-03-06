import WebKit

@MainActor
package protocol NetworkBodyFetching: AnyObject {
    func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody?
}

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
    private let bodyFetcher: any NetworkBodyFetching

    var hasAttachedPageWebView: Bool {
        pageAgent.webView != nil
    }

    public convenience init(configuration: NetworkConfiguration = .init()) {
        let pageAgent = NetworkPageAgent()
        self.init(configuration: configuration, pageAgent: pageAgent, bodyFetcher: pageAgent)
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        bodyFetcher: any NetworkBodyFetching
    ) {
        let pageAgent = NetworkPageAgent()
        self.init(configuration: configuration, pageAgent: pageAgent, bodyFetcher: bodyFetcher)
    }

    private init(
        configuration: NetworkConfiguration,
        pageAgent: NetworkPageAgent,
        bodyFetcher: any NetworkBodyFetching
    ) {
        self.configuration = configuration
        self.pageAgent = pageAgent
        self.bodyFetcher = bodyFetcher
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
        await bodyFetcher.fetchBody(ref: ref, handle: handle, role: role)
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

        let bodyRef = body.reference
        let bodyHandle = body.handle
        let hasReference = bodyRef?.isEmpty == false
        let hasHandle = bodyHandle != nil
        guard hasReference || hasHandle else {
            body.markFailed(.unavailable)
            return
        }

        body.markFetching()
        Task { @MainActor [weak self, weak entry, weak body] in
            guard let self, let entry, let body else {
                return
            }

            let fetched = await self.bodyFetcher.fetchBody(ref: bodyRef, handle: bodyHandle, role: role)

            guard self.body(for: entry, role: role) === body else {
                return
            }
            guard self.hasAttachedPageWebView else {
                if case .fetching = body.fetchState {
                    body.fetchState = .inline
                }
                return
            }
            guard let fetched else {
                body.markFailed(.unavailable)
                return
            }

            entry.applyFetchedBody(fetched, to: body)
        }
    }
}

private extension NetworkSession {
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

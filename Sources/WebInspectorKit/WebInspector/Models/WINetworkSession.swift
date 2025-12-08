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

    @discardableResult
    public func fetchBody(for entry: WINetworkEntry, role: WINetworkBody.Role) async -> WINetworkBody.FetchError? {
        guard let body = await networkAgent.fetchBody(
            requestID: entry.requestID,
            role: role
        ) else {
            if role == .request {
                if let existing = entry.requestBody {
                    existing.markFailed(.unavailable)
                }
            } else if let existing = entry.responseBody {
                existing.markFailed(.unavailable)
            }
            return .unavailable
        }
        applyFetchedBody(body, to: entry, role: role)
        return nil
    }

    private func applyFetchedBody(_ body: WINetworkBody, to entry: WINetworkEntry, role: WINetworkBody.Role) {
        body.fetchState = .full
        body.role = role
        if let existing = role == .request ? entry.requestBody : entry.responseBody {
            if let fullText = body.full ?? body.preview, !fullText.isEmpty {
                existing.applyFullBody(
                    fullText,
                    isBase64Encoded: body.isBase64Encoded,
                    size: body.size ?? fullText.count
                )
            }
            existing.summary = body.summary ?? existing.summary
            existing.formEntries = body.formEntries
            existing.kind = body.kind
            existing.fetchState = .full
            let updatedSize = existing.size ?? existing.full?.count ?? existing.preview?.count
            if let size = updatedSize {
                existing.size = size
                if role == .request {
                    entry.requestBodyBytesSent = size
                } else {
                    entry.decodedBodyLength = size
                }
            }
        } else {
            if role == .request {
                entry.requestBody = body
            } else {
                entry.responseBody = body
            }
            let size = body.size ?? body.full?.count ?? body.preview?.count
            if let size {
                body.size = size
                if role == .request {
                    entry.requestBodyBytesSent = size
                } else {
                    entry.decodedBodyLength = size
                }
            }
        }
    }
}

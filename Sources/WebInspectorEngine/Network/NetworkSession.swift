import Foundation
import WebKit

@MainActor
package protocol NetworkBodyFetching: AnyObject {
    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBodyFetchResult
}

package enum NetworkBodyFetchResult {
    case fetched(NetworkBody)
    case agentUnavailable
    case bodyUnavailable
}

@MainActor
public final class NetworkSession: PageSession {
    private struct BodyFetchKey: Hashable {
        let entryID: UUID
        let role: NetworkBody.Role
    }

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
    private var bodyFetchTasks: [BodyFetchKey: (token: UUID, task: Task<Void, Never>)] = [:]

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
        cancelAllBodyFetches()
        mode = .stopped
        pageAgent.detachPageWebView(preparing: .stopped)
    }

    public func detach() {
        cancelAllBodyFetches()
        mode = .stopped
        pageAgent.detachPageWebView(preparing: .stopped)
        lastPageWebView = nil
    }

    public func setMode(_ mode: NetworkLoggingMode) {
        self.mode = mode
        pageAgent.setMode(mode)
    }

    public func clearNetworkLogs() {
        cancelAllBodyFetches()
        pageAgent.clearNetworkLogs()
    }

    package func cancelBodyFetches(for entry: NetworkEntry) {
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .request), entry: entry)
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .response), entry: entry)
    }

    public func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        switch await bodyFetcher.fetchBodyResult(ref: ref, handle: handle, role: role) {
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

        guard body.currentDeferredLocator() != nil else {
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
            guard self.body(for: entry, role: role) === body else {
                return
            }
            guard let locator = body.currentDeferredLocator() else {
                body.markFailed(.unavailable)
                return
            }

            let fetchResult = await self.bodyFetcher.fetchBodyResult(
                ref: locator.reference,
                handle: locator.handle,
                role: role
            )

            guard !Task.isCancelled else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }

            guard self.body(for: entry, role: role) === body else {
                return
            }
            guard body.currentDeferredLocator() == locator else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
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
}

private extension NetworkSession {
    private func cancelAllBodyFetches() {
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

    private func resetBodyToInlineIfFetching(
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

    private func entry(forID id: UUID) -> NetworkEntry? {
        store.entries.first { $0.id == id }
    }

    private func shouldFetch(_ body: NetworkBody) -> Bool {
        switch body.fetchState {
        case .inline:
            return true
        case .fetching, .full, .failed:
            return false
        }
    }

    private func body(for entry: NetworkEntry, role: NetworkBody.Role) -> NetworkBody? {
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }
}

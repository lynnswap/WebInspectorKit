import WebKit

@MainActor
package enum WINetworkBodyFetchResult {
    case fetched(NetworkBody)
    case agentUnavailable
    case bodyUnavailable
}

package enum WINetworkBodyLoadError: Error, Equatable, Sendable {
    case agentUnavailable
    case bodyUnavailable
}

@MainActor
package protocol NetworkBodyFetching: AnyObject {
    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool
    func fetchBodyResult(
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> WINetworkBodyFetchResult
}

package extension NetworkBodyFetching {
    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        _ = role
        return true
    }
}

@MainActor
package protocol WINetworkBackend: AnyObject, NetworkBodyFetching {
    var webView: WKWebView? { get }
    var store: NetworkStore { get }
    var support: WIBackendSupport { get }

    func setMode(_ mode: NetworkLoggingMode) async
    func attachPageWebView(_ newWebView: WKWebView?) async
    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) async
    func clearNetworkLogs() async
    func tearDownForDeinit()

    func prepareForNavigationReconnect()
    func resumeAfterNavigationReconnect(to webView: WKWebView)
}

package extension WINetworkBackend {
    func prepareForNavigationReconnect() {}

    func resumeAfterNavigationReconnect(to webView: WKWebView) {
        _ = webView
    }

    func loadBodyIfNeeded(for entry: NetworkEntry, body: NetworkBody) async throws -> NetworkBody {
        let role = body.role
        guard webView != nil else {
            throw WINetworkBodyLoadError.agentUnavailable
        }

        switch body.fetchState {
        case .full:
            return body
        case .fetching:
            return body
        case .inline:
            break
        case .failed:
            throw WINetworkBodyLoadError.bodyUnavailable
        }

        guard supportsDeferredLoading(for: role) else {
            throw WINetworkBodyLoadError.agentUnavailable
        }
        guard let locator = body.deferredLocator else {
            body.markFailed(.unavailable)
            throw WINetworkBodyLoadError.bodyUnavailable
        }

        body.markFetching()
        do {
            let fetchResult = await fetchBodyResult(locator: locator, role: role)
            try Task.checkCancellation()
            guard webView != nil else {
                throw WINetworkBodyLoadError.agentUnavailable
            }
            guard currentBody(for: entry, role: role) === body else {
                throw CancellationError()
            }
            guard body.deferredLocator == locator else {
                throw CancellationError()
            }

            switch fetchResult {
            case .fetched(let fetched):
                entry.applyFetchedBody(fetched, to: body)
                return body
            case .agentUnavailable:
                body.markFailed(.unavailable)
                throw WINetworkBodyLoadError.agentUnavailable
            case .bodyUnavailable:
                body.markFailed(.unavailable)
                throw WINetworkBodyLoadError.bodyUnavailable
            }
        } catch is CancellationError {
            if case .fetching = body.fetchState {
                body.fetchState = .inline
            }
            throw CancellationError()
        } catch {
            if case .fetching = body.fetchState {
                body.fetchState = .inline
            }
            throw error
        }
    }

    private func currentBody(for entry: NetworkEntry, role: NetworkBody.Role) -> NetworkBody? {
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }
}

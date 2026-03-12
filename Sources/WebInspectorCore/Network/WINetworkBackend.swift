import WebKit

@MainActor
package enum WINetworkBodyFetchResult {
    case fetched(NetworkBody)
    case agentUnavailable
    case bodyUnavailable
}

@MainActor
package protocol NetworkBodyFetching: AnyObject {
    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool
    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult
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
    var support: WIInspectorBackendSupport { get }

    func setMode(_ mode: NetworkLoggingMode)
    func attachPageWebView(_ newWebView: WKWebView?)
    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?)
    func clearNetworkLogs()

    func prepareForNavigationReconnect()
    func resumeAfterNavigationReconnect()
}

package extension WINetworkBackend {
    func prepareForNavigationReconnect() {}

    func resumeAfterNavigationReconnect() {}
}

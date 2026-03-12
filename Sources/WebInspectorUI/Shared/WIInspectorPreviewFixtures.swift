#if DEBUG
import WebInspectorCore
import WebKit

@MainActor
enum WIInspectorPreviewFixtures {
    static func makeController() -> WIInspectorController {
        let domRuntime = WIDOMPreviewFixtures.makeRuntime()
        let domFrontendRuntime = WIDOMFrontendRuntime(session: domRuntime)
        let networkRuntime = WINetworkRuntime(
            configuration: .init(),
            backend: PreviewNetworkBackend()
        )
        return WIInspectorController(
            domSession: domRuntime,
            networkSession: networkRuntime,
            domFrontendBridge: domFrontendRuntime
        )
    }
}

@MainActor
private final class PreviewNetworkBackend: WINetworkBackend {
    weak var webView: WKWebView?
    let store = NetworkStore()
    let support = WIInspectorBackendSupport(
        availability: .supported,
        backendKind: .legacy,
        capabilities: [.networkDomain]
    )

    func setMode(_ mode: NetworkLoggingMode) {
        store.setRecording(mode != .stopped)
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        webView = newWebView
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        _ = modeBeforeDetach
        webView = nil
    }

    func clearNetworkLogs() {
        store.clear()
    }

    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        _ = role
        return false
    }

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        _ = ref
        _ = handle
        _ = role
        return .bodyUnavailable
    }
}
#endif

import WebInspectorCore

package extension WIBridgeMode {
    func domBackendSupport() -> WIBackendSupport {
        WIBackendSupport(
            availability: .supported,
            backendKind: inspectorBackendKind,
            capabilities: [.domDomain]
        )
    }

    func networkBackendSupport() -> WIBackendSupport {
        WIBackendSupport(
            availability: .supported,
            backendKind: inspectorBackendKind,
            capabilities: [.networkDomain]
        )
    }

    private var inspectorBackendKind: WIBackendKind {
        switch self {
        case .privateCore:
            .privateCore
        case .privateFull:
            .privateFull
        case .legacyJSON:
            .legacy
        }
    }
}

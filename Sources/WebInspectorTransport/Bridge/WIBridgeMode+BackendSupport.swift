import WebInspectorCore

package extension WIBridgeMode {
    func domBackendSupport() -> WIInspectorBackendSupport {
        WIInspectorBackendSupport(
            availability: .supported,
            backendKind: inspectorBackendKind,
            capabilities: [.domDomain]
        )
    }

    func networkBackendSupport() -> WIInspectorBackendSupport {
        WIInspectorBackendSupport(
            availability: .supported,
            backendKind: inspectorBackendKind,
            capabilities: [.networkDomain]
        )
    }

    private var inspectorBackendKind: WIInspectorBackendKind {
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

import WebInspectorCore

package extension WITransportSupportSnapshot {
    var inspectorBackendSupport: WIInspectorBackendSupport {
        let resolvedBackendKind: WIInspectorBackendKind
        switch self.backendKind {
        case .iOSNativeInspector:
            resolvedBackendKind = .nativeInspectorIOS
        case .macOSNativeInspector:
            resolvedBackendKind = .nativeInspectorMacOS
        case .unsupported:
            resolvedBackendKind = .unsupported
        }

        let mappedCapabilities = Set(
            capabilities.compactMap { capability in
                WIInspectorBackendCapability(rawValue: capability.rawValue)
            }
        )

        return WIInspectorBackendSupport(
            availability: availability == .supported ? .supported : .unsupported,
            backendKind: resolvedBackendKind,
            capabilities: mappedCapabilities,
            failureReason: failureReason
        )
    }
}

import WebInspectorCore

package extension WITransportSupportSnapshot {
    var backendSupport: WIBackendSupport {
        let resolvedBackendKind: WIBackendKind
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
                WIBackendCapability(rawValue: capability.rawValue)
            }
        )

        return WIBackendSupport(
            availability: availability == .supported ? .supported : .unsupported,
            backendKind: resolvedBackendKind,
            capabilities: mappedCapabilities,
            failureReason: failureReason
        )
    }
}

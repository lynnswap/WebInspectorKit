package struct NativeInspectorSymbolAddresses: Sendable, Equatable {
    package let connectFrontendAddress: UInt64
    package let disconnectFrontendAddress: UInt64
    package let stringFromUTF8Address: UInt64
    package let stringImplToNSStringAddress: UInt64
    package let destroyStringImplAddress: UInt64
    package let backendDispatcherDispatchAddress: UInt64

    package static let zero = NativeInspectorSymbolAddresses(
        connectFrontendAddress: 0,
        disconnectFrontendAddress: 0,
        stringFromUTF8Address: 0,
        stringImplToNSStringAddress: 0,
        destroyStringImplAddress: 0,
        backendDispatcherDispatchAddress: 0
    )

    package var isComplete: Bool {
        connectFrontendAddress != 0
            && disconnectFrontendAddress != 0
            && stringFromUTF8Address != 0
            && stringImplToNSStringAddress != 0
            && destroyStringImplAddress != 0
            && backendDispatcherDispatchAddress != 0
    }
}

package struct NativeInspectorSymbolResolution: Sendable, Equatable {
    package let addresses: NativeInspectorSymbolAddresses
    package let failureReason: String?
    package let failureKind: String?
    package let phase: String?
    package let missingFunctions: [String]
    package let source: String?
    package let usedConnectDisconnectFallback: Bool

    package var connectFrontendAddress: UInt64 { addresses.connectFrontendAddress }
    package var disconnectFrontendAddress: UInt64 { addresses.disconnectFrontendAddress }
    package var stringFromUTF8Address: UInt64 { addresses.stringFromUTF8Address }
    package var stringImplToNSStringAddress: UInt64 { addresses.stringImplToNSStringAddress }
    package var destroyStringImplAddress: UInt64 { addresses.destroyStringImplAddress }
    package var backendDispatcherDispatchAddress: UInt64 { addresses.backendDispatcherDispatchAddress }

    package var diagnosticsSummary: String? {
        var parts = [String]()
        if let phase, !phase.isEmpty {
            parts.append("phase=\(phase)")
        }
        if let source, !source.isEmpty {
            parts.append("source=\(source)")
        }
        if let failureKind, !failureKind.isEmpty {
            parts.append("failure=\(failureKind)")
        }
        if !missingFunctions.isEmpty {
            parts.append("missing=\(missingFunctions.joined(separator: ","))")
        }
        if usedConnectDisconnectFallback {
            parts.append("fallback=text-scan")
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " ")
    }

    package var isSupported: Bool {
        addresses.isComplete && failureReason == nil
    }
}

struct NativeInspectorSymbolAddresses: Sendable, Equatable {
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let stringFromUTF8Address: UInt64
    let stringImplToNSStringAddress: UInt64
    let destroyStringImplAddress: UInt64
    let backendDispatcherDispatchAddress: UInt64

    static let zero = NativeInspectorSymbolAddresses(
        connectFrontendAddress: 0,
        disconnectFrontendAddress: 0,
        stringFromUTF8Address: 0,
        stringImplToNSStringAddress: 0,
        destroyStringImplAddress: 0,
        backendDispatcherDispatchAddress: 0
    )

    var isComplete: Bool {
        connectFrontendAddress != 0
            && disconnectFrontendAddress != 0
            && stringFromUTF8Address != 0
            && stringImplToNSStringAddress != 0
            && destroyStringImplAddress != 0
            && backendDispatcherDispatchAddress != 0
    }
}

struct NativeInspectorSymbolResolution: Sendable, Equatable {
    let addresses: NativeInspectorSymbolAddresses
    let failureReason: String?
    let failureKind: String?
    let phase: String?
    let missingFunctions: [String]
    let source: String?
    let usedConnectDisconnectFallback: Bool

    var connectFrontendAddress: UInt64 { addresses.connectFrontendAddress }
    var disconnectFrontendAddress: UInt64 { addresses.disconnectFrontendAddress }
    var stringFromUTF8Address: UInt64 { addresses.stringFromUTF8Address }
    var stringImplToNSStringAddress: UInt64 { addresses.stringImplToNSStringAddress }
    var destroyStringImplAddress: UInt64 { addresses.destroyStringImplAddress }
    var backendDispatcherDispatchAddress: UInt64 { addresses.backendDispatcherDispatchAddress }

    var diagnosticsSummary: String? {
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
            parts.append("textScanFallback=true")
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " ")
    }

    var isSupported: Bool {
        addresses.isComplete && failureReason == nil
    }
}

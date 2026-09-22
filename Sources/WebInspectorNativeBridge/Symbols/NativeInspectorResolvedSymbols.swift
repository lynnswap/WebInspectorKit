import WebInspectorNativeBridgeObjC
import WebKitRuntime

package struct NativeInspectorSymbolResolutionError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Failure: Sendable {
        let role: NativeInspectorSymbolRole
        let underlyingError: RuntimeLookupError
    }

    let failures: [Failure]

    package var diagnostics: [String] {
        failures.map {
            "Native Web Inspector requirement \($0.role.rawValue) failed: \($0.underlyingError.reason.rawValue)."
        }
    }

    package var description: String { diagnostics.joined(separator: " ") }
    package var debugDescription: String { description }
}

package struct NativeInspectorResolvedSymbols: Equatable, Sendable {
    let connectFrontend: ResolvedRuntimeSymbol
    let disconnectFrontend: ResolvedRuntimeSymbol
    let stringFromUTF8: ResolvedRuntimeSymbol
    let stringImplToNSString: ResolvedRuntimeSymbol
    let derefStringImpl: ResolvedRuntimeSymbol
    let dispatchMessageFromRemote: ResolvedRuntimeSymbol
    let debuggableVTable: ResolvedRuntimeSymbol

    var objcSymbols: WebInspectorNativeResolvedSymbols {
        WebInspectorNativeResolvedSymbols(
            connectFrontendAddress: connectFrontend.address,
            disconnectFrontendAddress: disconnectFrontend.address,
            stringFromUTF8Address: stringFromUTF8.address,
            stringImplToNSStringAddress: stringImplToNSString.address,
            derefStringImplAddress: derefStringImpl.address,
            dispatchMessageFromRemoteAddress: dispatchMessageFromRemote.address,
            debuggableVTableAddress: debuggableVTable.address
        )
    }

    package static func resolveCurrent() throws -> NativeInspectorResolvedSymbols {
        try NativeInspectorSymbolResolver.resolveCurrent()
    }

    package static func resolveCurrentDetached() async throws -> NativeInspectorResolvedSymbols {
        try await Task.detached(priority: .userInitiated) { try resolveCurrent() }.value
    }
}

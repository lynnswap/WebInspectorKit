import WebInspectorNativeBridgeObjC
import WebKitRuntime
import ABIBridgeCore

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

    @unsafe func withObjCSymbols<Result>(_ body: (WebInspectorNativeResolvedSymbols) throws -> Result) rethrows -> Result {
        let handles = unsafe [connectFrontend, disconnectFrontend, stringFromUTF8, stringImplToNSString,
                       derefStringImpl, dispatchMessageFromRemote, debuggableVTable]
            .map { unsafe $0.copyNativeHandle() }
        defer { unsafe handles.forEach { unsafe ABIReleaseResolvedSymbol($0) } }
        let symbols = unsafe WebInspectorNativeResolvedSymbols(
            connectFrontend: handles[0], disconnectFrontend: handles[1],
            stringFromUTF8: handles[2], stringImplToNSString: handles[3],
            derefStringImpl: handles[4], dispatchMessageFromRemote: handles[5], debuggableVTable: handles[6]
        )
        return try unsafe body(symbols)
    }

    package static func resolveCurrent() async throws -> NativeInspectorResolvedSymbols {
        try await NativeInspectorSymbolResolver.resolveCurrent()
    }
}

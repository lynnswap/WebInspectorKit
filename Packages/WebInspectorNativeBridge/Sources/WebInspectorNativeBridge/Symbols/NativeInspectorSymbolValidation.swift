#if os(iOS) || os(macOS)
import Foundation

extension NativeInspectorSymbolResolverCore {
    static func resolvedFunctionAddresses(
        from resolvedSymbols: NativeInspectorResolvedSymbolSet
    ) -> NativeInspectorSymbolAddresses? {
        guard
            case let .found(connectAddress) = resolvedSymbols.connectFrontend,
            case let .found(disconnectAddress) = resolvedSymbols.disconnectFrontend,
            case let .found(stringFromUTF8Address) = resolvedSymbols.stringFromUTF8,
            case let .found(stringImplToNSStringAddress) = resolvedSymbols.stringImplToNSString,
            case let .found(derefStringImplAddress) = resolvedSymbols.derefStringImpl,
            case let .found(dispatchMessageFromRemoteAddress) = resolvedSymbols.dispatchMessageFromRemote,
            case let .found(debuggableVTableAddress) = resolvedSymbols.debuggableVTable
        else {
            return nil
        }

        return NativeInspectorSymbolAddresses(
            connectFrontendAddress: connectAddress,
            disconnectFrontendAddress: disconnectAddress,
            stringFromUTF8Address: stringFromUTF8Address,
            stringImplToNSStringAddress: stringImplToNSStringAddress,
            derefStringImplAddress: derefStringImplAddress,
            dispatchMessageFromRemoteAddress: dispatchMessageFromRemoteAddress,
            debuggableVTableAddress: debuggableVTableAddress
        )
    }

    static func expectedHeaderAddressesForAttachEntryPoints(
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt
    ) -> [UInt] {
        return [webKitHeaderAddress]
    }

    static func successResolution(
        _ functionAddresses: NativeInspectorSymbolAddresses,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
    ) -> NativeInspectorSymbolLookupResult {
        #if DEBUG
        if let phase {
            NativeInspectorSymbolLog.info(
                unsafe String(
                    format: "[WebInspectorNativeBridge] native inspector symbols resolved backend=native-inspector status=complete phase=%@ source=%@ connectFrontend=0x%llx disconnectFrontend=0x%llx stringFromUTF8=0x%llx stringImplToNSString=0x%llx derefStringImpl=0x%llx dispatchMessageFromRemote=0x%llx",
                    phase.message,
                    source ?? "unknown",
                    functionAddresses.connectFrontendAddress,
                    functionAddresses.disconnectFrontendAddress,
                    functionAddresses.stringFromUTF8Address,
                    functionAddresses.stringImplToNSStringAddress,
                    functionAddresses.derefStringImplAddress,
                    functionAddresses.dispatchMessageFromRemoteAddress,
                )
            )
        }
        #endif
        return NativeInspectorSymbolLookupResult(
            functionAddresses: functionAddresses,
            failureReason: nil,
            failureKind: nil,
            phase: phase,
            missingFunctions: [],
            source: source,
        )
    }

    static func successfulResolutionIfComplete(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
    ) -> NativeInspectorSymbolLookupResult? {
        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
            resolvedSymbols.stringFromUTF8,
            resolvedSymbols.stringImplToNSString,
            resolvedSymbols.derefStringImpl,
            resolvedSymbols.dispatchMessageFromRemote,
            resolvedSymbols.debuggableVTable,
        ]

        guard allResults.allSatisfy({
            if case .found = $0 {
                return true
            }
            return false
        }) else {
            return nil
        }

        for result in allResults {
            if case .outsideSection = result {
                return nil
            }
        }

        let attachHeaders = expectedHeaderAddressesForAttachEntryPoints(
            webKitHeaderAddress: webKitHeaderAddress,
            javaScriptCoreHeaderAddress: javaScriptCoreHeaderAddress
        )
        let expectedHeadersBySymbol: [(ResolvedNativeInspectorAddress, [UInt])] = [
            (resolvedSymbols.connectFrontend, attachHeaders),
            (resolvedSymbols.disconnectFrontend, attachHeaders),
            (resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.derefStringImpl, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
            (resolvedSymbols.dispatchMessageFromRemote, [webKitHeaderAddress]),
            (resolvedSymbols.debuggableVTable, [webKitHeaderAddress]),
        ]
        for (result, expectedHeaders) in expectedHeadersBySymbol {
            guard case let .found(address) = result else {
                return nil
            }
            guard resolvedAddress(address, belongsToAnyOf: expectedHeaders) else {
                return nil
            }
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return nil
        }
        return successResolution(
            functionAddresses,
            phase: phase,
            source: source,
        )
    }

    static func finalizeResolution(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        shouldLogFailure: Bool = true
    ) -> NativeInspectorSymbolLookupResult? {
        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
            resolvedSymbols.stringFromUTF8,
            resolvedSymbols.stringImplToNSString,
            resolvedSymbols.derefStringImpl,
            resolvedSymbols.dispatchMessageFromRemote,
            resolvedSymbols.debuggableVTable,
        ]

        for result in allResults {
            if case .outsideSection = result {
                return failure(
                    .resolvedAddressOutsideSection,
                    phase: phase,
                    source: source,
                    missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                    shouldLog: shouldLogFailure
                )
            }
        }

        if allResults.contains(where: {
            if case .ambiguous = $0 {
                return true
            }
            return false
        }) {
            return failure(
                .ambiguousSymbolMatch,
                phase: phase,
                source: source,
                missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                shouldLog: shouldLogFailure
            )
        }

        let attachHeaders = expectedHeaderAddressesForAttachEntryPoints(
            webKitHeaderAddress: webKitHeaderAddress,
            javaScriptCoreHeaderAddress: javaScriptCoreHeaderAddress
        )
        let expectedHeadersBySymbol: [(ResolvedNativeInspectorAddress, [UInt])] = [
            (resolvedSymbols.connectFrontend, attachHeaders),
            (resolvedSymbols.disconnectFrontend, attachHeaders),
            (resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.derefStringImpl, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
            (resolvedSymbols.dispatchMessageFromRemote, [webKitHeaderAddress]),
            (resolvedSymbols.debuggableVTable, [webKitHeaderAddress]),
        ]
        for (result, expectedHeaders) in expectedHeadersBySymbol {
            guard case let .found(address) = result else {
                continue
            }
            guard resolvedAddress(address, belongsToAnyOf: expectedHeaders) else {
                return failure(
                    .resolvedAddressImageMismatch,
                    phase: phase,
                    source: source,
                    missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                    shouldLog: shouldLogFailure
                )
            }
        }

        let missingFunctions = unsafe missingFunctionNames(in: resolvedSymbols)
        let missingConnectDisconnect = missingFunctions.filter {
            $0 == "connectFrontend" || $0 == "disconnectFrontend"
        }
        if !missingConnectDisconnect.isEmpty {
            return failure(
                .connectDisconnectSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: missingConnectDisconnect,
                shouldLog: shouldLogFailure
            )
        }

        let missingRuntimeFunctions = missingFunctions.filter {
            $0 != "connectFrontend" && $0 != "disconnectFrontend"
        }
        if !missingRuntimeFunctions.isEmpty {
            return failure(
                .runtimeFunctionSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: missingRuntimeFunctions,
                shouldLog: shouldLogFailure
            )
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return failure(
                .runtimeFunctionSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                shouldLog: shouldLogFailure
            )
        }
        return successResolution(
            functionAddresses,
            phase: phase,
            source: source,
        )
    }

}
#endif

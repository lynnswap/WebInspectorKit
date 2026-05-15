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
            case let .found(destroyStringImplAddress) = resolvedSymbols.destroyStringImpl,
            case let .found(backendDispatcherDispatchAddress) = resolvedSymbols.backendDispatcherDispatch
        else {
            return nil
        }

        return NativeInspectorSymbolAddresses(
            connectFrontendAddress: connectAddress,
            disconnectFrontendAddress: disconnectAddress,
            stringFromUTF8Address: stringFromUTF8Address,
            stringImplToNSStringAddress: stringImplToNSStringAddress,
            destroyStringImplAddress: destroyStringImplAddress,
            backendDispatcherDispatchAddress: backendDispatcherDispatchAddress
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
        usedConnectDisconnectFallback: Bool
    ) -> NativeInspectorSymbolLookupResult {
        #if DEBUG
        if let phase {
            NativeInspectorSymbolLog.info(
                unsafe String(
                    format: "[WebInspectorNativeSymbols] native inspector symbols resolved backend=native-inspector status=complete phase=%@ source=%@ connectFrontend=0x%llx disconnectFrontend=0x%llx stringFromUTF8=0x%llx stringImplToNSString=0x%llx destroyStringImpl=0x%llx backendDispatcherDispatch=0x%llx textScanFallback=%@",
                    phase.message,
                    source ?? "unknown",
                    functionAddresses.connectFrontendAddress,
                    functionAddresses.disconnectFrontendAddress,
                    functionAddresses.stringFromUTF8Address,
                    functionAddresses.stringImplToNSStringAddress,
                    functionAddresses.destroyStringImplAddress,
                    functionAddresses.backendDispatcherDispatchAddress,
                    usedConnectDisconnectFallback ? "true" : "false"
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
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    static func successfulResolutionIfComplete(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        usedConnectDisconnectFallback: Bool
    ) -> NativeInspectorSymbolLookupResult? {
        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
            resolvedSymbols.stringFromUTF8,
            resolvedSymbols.stringImplToNSString,
            resolvedSymbols.destroyStringImpl,
            resolvedSymbols.backendDispatcherDispatch,
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
            if case .outsideText = result {
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
            (resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
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
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    static func finalizeResolution(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        usedConnectDisconnectFallback: Bool,
        shouldLogFailure: Bool = true
    ) -> NativeInspectorSymbolLookupResult? {
        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
            resolvedSymbols.stringFromUTF8,
            resolvedSymbols.stringImplToNSString,
            resolvedSymbols.destroyStringImpl,
            resolvedSymbols.backendDispatcherDispatch,
        ]

        for result in allResults {
            if case .outsideText = result {
                return failure(
                    .resolvedAddressOutsideText,
                    phase: phase,
                    source: source,
                    missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                    usedConnectDisconnectFallback: usedConnectDisconnectFallback,
                    shouldLog: shouldLogFailure
                )
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
            (resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
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
                    usedConnectDisconnectFallback: usedConnectDisconnectFallback,
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
                usedConnectDisconnectFallback: usedConnectDisconnectFallback,
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
                usedConnectDisconnectFallback: usedConnectDisconnectFallback,
                shouldLog: shouldLogFailure
            )
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return failure(
                .runtimeFunctionSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                usedConnectDisconnectFallback: usedConnectDisconnectFallback,
                shouldLog: shouldLogFailure
            )
        }
        return successResolution(
            functionAddresses,
            phase: phase,
            source: source,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

}
#endif

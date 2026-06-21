#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    @unsafe static func resolveUsingSharedCache(
        loadedImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedWebCoreImage: LoadedNativeInspectorImage?,
        webCorePathSuffixes: [String] = webCoreImagePathSuffixes,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        let loadedCacheResolution = unsafe resolveUsingLoadedSharedCache(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        )
        if loadedCacheResolution.failureReason == nil {
            return loadedCacheResolution
        }

        #if DEBUG
        logResolutionAttemptIncomplete(
            loadedCacheResolution,
            nextAttempt: "full-cache"
        )
        #endif

        let fullCacheResolution = unsafe resolveUsingFullSharedCache(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        )
        return mergedResolution(
            preferred: loadedCacheResolution,
            fallback: fullCacheResolution
        )
    }

    @unsafe private static func resolveUsingLoadedSharedCache(
        loadedImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedWebCoreImage: LoadedNativeInspectorImage?,
        webCorePathSuffixes: [String],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        guard let context = unsafe loadedSharedCacheContext(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes
        ) else {
            return failure(.sharedCacheUnavailable, shouldLog: false)
        }

        var lastResolvedSymbols: NativeInspectorResolvedSymbolSet?
        if let resolvedSymbols = resolveLocalSymbols(
            webKit: context.webKit,
            javaScriptCore: context.javaScriptCore,
            symbols64: context.localSymbols,
            entries: context.localSymbolEntries,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        ) {
            let resolution = unsafe finalizedSharedCacheResolution(
                resolvedSymbols,
                phase: .sharedCache,
                sourceBase: "shared-cache",
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                loadedImageSymbols: loadedImageSymbols,
                runtimeWebKit: context.webKit,
                runtimeJavaScriptCore: context.javaScriptCore,
                runtimeWebCore: context.webCore,
                symbols: symbols
            )
            lastResolvedSymbols = resolution.resolvedSymbols
            if let lookupResult = resolution.lookupResult {
                return lookupResult
            }
        }

        do {
            let fileBackedContexts = try fileBackedLocalSymbolContexts(
                mainCacheHeader: context.cache.mainCacheHeader
            )
            if let resolvedSymbols = try resolveFileBackedSymbols(
                webKit: context.webKit,
                javaScriptCore: context.javaScriptCore,
                fileBackedContexts: fileBackedContexts,
                loadedImageSymbols: loadedImageSymbols,
                symbols: symbols
            ) {
                let resolution = unsafe finalizedSharedCacheResolution(
                    resolvedSymbols,
                    phase: .sharedCacheFile,
                    sourceBase: "shared-cache-file",
                    loadedImage: loadedImage,
                    loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                    loadedImageSymbols: loadedImageSymbols,
                    runtimeWebKit: context.webKit,
                    runtimeJavaScriptCore: context.javaScriptCore,
                    runtimeWebCore: context.webCore,
                    symbols: symbols
                )
                lastResolvedSymbols = resolution.resolvedSymbols
                if let lookupResult = resolution.lookupResult {
                    return lookupResult
                }
            }
        } catch let lookupFailure as NativeInspectorSymbolLookupFailure {
            return fallbackResolution(
                lastResolvedSymbols,
                phase: .sharedCacheFile,
                source: "shared-cache-file",
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                fallbackFailure: lookupFailure
            )
        } catch {
            return fallbackResolution(
                lastResolvedSymbols,
                phase: .sharedCacheFile,
                source: "shared-cache-file",
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                fallbackFailure: NativeInspectorSymbolLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: nil
                )
            )
        }

        return fallbackResolution(
            lastResolvedSymbols,
            phase: .sharedCache,
            source: "shared-cache",
            loadedImage: loadedImage,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            fallbackFailure: NativeInspectorSymbolLookupFailure(
                kind: .runtimeFunctionSymbolMissing,
                detail: nil
            )
        )
    }

    @unsafe private static func resolveUsingFullSharedCache(
        loadedImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedWebCoreImage: LoadedNativeInspectorImage?,
        webCorePathSuffixes: [String],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        guard let context = unsafe fullSharedCacheContext(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes
        ) else {
            return failure(.sharedCacheUnavailable, shouldLog: false)
        }

        var lastResolvedSymbols: NativeInspectorResolvedSymbolSet?
        if let resolvedSymbols = resolveLocalSymbols(
            webKit: context.webKit,
            javaScriptCore: context.javaScriptCore,
            symbols64: context.localSymbols,
            entries: context.localSymbolEntries,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        ) {
            let resolution = finalizedFileSharedCacheResolution(
                resolvedSymbols,
                phase: .fullCache,
                sourceBase: "full-cache",
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                loadedImageSymbols: loadedImageSymbols
            )
            lastResolvedSymbols = resolution.resolvedSymbols
            if let lookupResult = resolution.lookupResult {
                return lookupResult
            }
        }

        do {
            let fileBackedContexts = try fileBackedLocalSymbolContexts(
                mainCacheHeader: context.cache.mainCacheHeader
            )
            if let resolvedSymbols = try resolveFileBackedSymbols(
                webKit: context.webKit,
                javaScriptCore: context.javaScriptCore,
                fileBackedContexts: fileBackedContexts,
                loadedImageSymbols: loadedImageSymbols,
                symbols: symbols
            ) {
                let resolution = finalizedFileSharedCacheResolution(
                    resolvedSymbols,
                    phase: .fullCacheFile,
                    sourceBase: "full-cache-file",
                    loadedImage: loadedImage,
                    loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                    loadedImageSymbols: loadedImageSymbols
                )
                lastResolvedSymbols = resolution.resolvedSymbols
                if let lookupResult = resolution.lookupResult {
                    return lookupResult
                }
            }
        } catch let lookupFailure as NativeInspectorSymbolLookupFailure {
            return fallbackResolution(
                lastResolvedSymbols,
                phase: .fullCacheFile,
                source: "full-cache-file",
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                fallbackFailure: lookupFailure
            )
        } catch {
            return fallbackResolution(
                lastResolvedSymbols,
                phase: .fullCacheFile,
                source: "full-cache-file",
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                fallbackFailure: NativeInspectorSymbolLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: nil
                )
            )
        }

        return fallbackResolution(
            lastResolvedSymbols,
            phase: .fullCache,
            source: "full-cache",
            loadedImage: loadedImage,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            fallbackFailure: NativeInspectorSymbolLookupFailure(
                kind: .runtimeFunctionSymbolMissing,
                detail: nil
            )
        )
    }

    private static func resolveLocalSymbols(
        webKit: NativeInspectorSharedCacheImageContext<MachOImage>,
        javaScriptCore: NativeInspectorSharedCacheImageContext<MachOImage>,
        symbols64: MachOImage.Symbols64?,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorResolvedSymbolSet? {
        guard let symbols64,
              let webKitRange = localSymbolRange(for: webKit.dylibOffset, entries: entries, symbolCount: symbols64.count),
              let javaScriptCoreRange = localSymbolRange(for: javaScriptCore.dylibOffset, entries: entries, symbolCount: symbols64.count) else {
            return nil
        }
        return resolveSymbols(
            webKit: webKit,
            javaScriptCore: javaScriptCore,
            webKitSymbols: symbols64,
            webKitSymbolRange: webKitRange,
            javaScriptCoreSymbols: symbols64,
            javaScriptCoreSymbolRange: javaScriptCoreRange,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        )
    }

    private static func resolveLocalSymbols(
        webKit: NativeInspectorSharedCacheImageContext<MachOFile>,
        javaScriptCore: NativeInspectorSharedCacheImageContext<MachOFile>,
        symbols64: MachOFile.Symbols64?,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorResolvedSymbolSet? {
        guard let symbols64,
              let webKitRange = localSymbolRange(for: webKit.dylibOffset, entries: entries, symbolCount: symbols64.count),
              let javaScriptCoreRange = localSymbolRange(for: javaScriptCore.dylibOffset, entries: entries, symbolCount: symbols64.count) else {
            return nil
        }
        return resolveSymbols(
            webKit: webKit,
            javaScriptCore: javaScriptCore,
            webKitSymbols: symbols64,
            webKitSymbolRange: webKitRange,
            javaScriptCoreSymbols: symbols64,
            javaScriptCoreSymbolRange: javaScriptCoreRange,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        )
    }

    private static func resolveFileBackedSymbols(
        webKit: NativeInspectorSharedCacheImageContext<MachOImage>,
        javaScriptCore: NativeInspectorSharedCacheImageContext<MachOImage>,
        fileBackedContexts: [NativeInspectorFileBackedLocalSymbolContext],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) throws -> NativeInspectorResolvedSymbolSet? {
        let webKitSymbols = try fileBackedLocalSymbols(in: fileBackedContexts, dylibOffset: webKit.dylibOffset)
        let javaScriptCoreSymbols = try fileBackedLocalSymbols(in: fileBackedContexts, dylibOffset: javaScriptCore.dylibOffset)
        return resolveSymbols(
            webKit: webKit,
            javaScriptCore: javaScriptCore,
            webKitSymbols: webKitSymbols.symbols,
            webKitSymbolRange: webKitSymbols.symbolRange,
            javaScriptCoreSymbols: javaScriptCoreSymbols.symbols,
            javaScriptCoreSymbolRange: javaScriptCoreSymbols.symbolRange,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        )
    }

    private static func resolveFileBackedSymbols(
        webKit: NativeInspectorSharedCacheImageContext<MachOFile>,
        javaScriptCore: NativeInspectorSharedCacheImageContext<MachOFile>,
        fileBackedContexts: [NativeInspectorFileBackedLocalSymbolContext],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) throws -> NativeInspectorResolvedSymbolSet? {
        let webKitSymbols = try fileBackedLocalSymbols(in: fileBackedContexts, dylibOffset: webKit.dylibOffset)
        let javaScriptCoreSymbols = try fileBackedLocalSymbols(in: fileBackedContexts, dylibOffset: javaScriptCore.dylibOffset)
        return resolveSymbols(
            webKit: webKit,
            javaScriptCore: javaScriptCore,
            webKitSymbols: webKitSymbols.symbols,
            webKitSymbolRange: webKitSymbols.symbolRange,
            javaScriptCoreSymbols: javaScriptCoreSymbols.symbols,
            javaScriptCoreSymbolRange: javaScriptCoreSymbols.symbolRange,
            loadedImageSymbols: loadedImageSymbols,
            symbols: symbols
        )
    }

    private static func resolveSymbols(
        webKit: NativeInspectorSharedCacheImageContext<MachOImage>,
        javaScriptCore: NativeInspectorSharedCacheImageContext<MachOImage>,
        webKitSymbols: MachOImage.Symbols64,
        webKitSymbolRange: Range<Int>,
        javaScriptCoreSymbols: MachOImage.Symbols64,
        javaScriptCoreSymbolRange: Range<Int>,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorResolvedSymbolSet {
        let webKitTargets = sharedCacheTargets(
            loadedImageSymbols: loadedImageSymbols,
            [
                NativeInspectorSymbolMatchTarget(role: .connectFrontend, symbol: symbols.connectFrontend),
                NativeInspectorSymbolMatchTarget(role: .disconnectFrontend, symbol: symbols.disconnectFrontend),
                NativeInspectorSymbolMatchTarget(role: .backendDispatcherDispatch, symbol: symbols.backendDispatcherDispatch),
            ]
        )
        let webKitResults = webKitTargets.isEmpty ? [:] : unsafe resolveSharedCacheSymbols(
            matching: webKitTargets,
            symbols: webKitSymbols,
            symbolRange: webKitSymbolRange,
            textVMAddress: UInt64(webKit.text.virtualMemoryAddress),
            textRange: webKit.textRange,
            slide: webKit.slide
        )
        var javaScriptCoreTargets = sharedCacheTargets(
            loadedImageSymbols: loadedImageSymbols,
            [
                NativeInspectorSymbolMatchTarget(role: .stringFromUTF8, symbol: symbols.stringFromUTF8),
                NativeInspectorSymbolMatchTarget(role: .stringImplToNSString, symbol: symbols.stringImplToNSString),
                NativeInspectorSymbolMatchTarget(role: .destroyStringImpl, symbol: symbols.destroyStringImpl),
            ]
        )
        if !loadedImageSymbols.address(for: .backendDispatcherDispatch).isFound,
           case .missing = webKitResults[.backendDispatcherDispatch] ?? .missing {
            javaScriptCoreTargets.append(
                NativeInspectorSymbolMatchTarget(role: .backendDispatcherDispatch, symbol: symbols.backendDispatcherDispatch)
            )
        }
        let javaScriptCoreResults = javaScriptCoreTargets.isEmpty ? [:] : unsafe resolveSharedCacheSymbols(
            matching: javaScriptCoreTargets,
            symbols: javaScriptCoreSymbols,
            symbolRange: javaScriptCoreSymbolRange,
            textVMAddress: UInt64(javaScriptCore.text.virtualMemoryAddress),
            textRange: javaScriptCore.textRange,
            slide: javaScriptCore.slide
        )
        return NativeInspectorResolvedSymbolSet(
            connectFrontend: webKitResults[.connectFrontend] ?? .missing,
            disconnectFrontend: webKitResults[.disconnectFrontend] ?? .missing,
            stringFromUTF8: javaScriptCoreResults[.stringFromUTF8] ?? .missing,
            stringImplToNSString: javaScriptCoreResults[.stringImplToNSString] ?? .missing,
            destroyStringImpl: javaScriptCoreResults[.destroyStringImpl] ?? .missing,
            backendDispatcherDispatch: preferredResolvedAddress(
                webKitResults[.backendDispatcherDispatch] ?? .missing,
                fallback: javaScriptCoreResults[.backendDispatcherDispatch] ?? .missing
            )
        )
    }

    private static func resolveSymbols<Image>(
        webKit: NativeInspectorSharedCacheImageContext<Image>,
        javaScriptCore: NativeInspectorSharedCacheImageContext<Image>,
        webKitSymbols: MachOFile.Symbols64,
        webKitSymbolRange: Range<Int>,
        javaScriptCoreSymbols: MachOFile.Symbols64,
        javaScriptCoreSymbolRange: Range<Int>,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorResolvedSymbolSet {
        let webKitTargets = sharedCacheTargets(
            loadedImageSymbols: loadedImageSymbols,
            [
                NativeInspectorSymbolMatchTarget(role: .connectFrontend, symbol: symbols.connectFrontend),
                NativeInspectorSymbolMatchTarget(role: .disconnectFrontend, symbol: symbols.disconnectFrontend),
                NativeInspectorSymbolMatchTarget(role: .backendDispatcherDispatch, symbol: symbols.backendDispatcherDispatch),
            ]
        )
        let webKitResults = webKitTargets.isEmpty ? [:] : unsafe resolveSharedCacheSymbols(
            matching: webKitTargets,
            symbols: webKitSymbols,
            symbolRange: webKitSymbolRange,
            textVMAddress: UInt64(webKit.text.virtualMemoryAddress),
            textRange: webKit.textRange,
            slide: webKit.slide
        )
        var javaScriptCoreTargets = sharedCacheTargets(
            loadedImageSymbols: loadedImageSymbols,
            [
                NativeInspectorSymbolMatchTarget(role: .stringFromUTF8, symbol: symbols.stringFromUTF8),
                NativeInspectorSymbolMatchTarget(role: .stringImplToNSString, symbol: symbols.stringImplToNSString),
                NativeInspectorSymbolMatchTarget(role: .destroyStringImpl, symbol: symbols.destroyStringImpl),
            ]
        )
        if !loadedImageSymbols.address(for: .backendDispatcherDispatch).isFound,
           case .missing = webKitResults[.backendDispatcherDispatch] ?? .missing {
            javaScriptCoreTargets.append(
                NativeInspectorSymbolMatchTarget(role: .backendDispatcherDispatch, symbol: symbols.backendDispatcherDispatch)
            )
        }
        let javaScriptCoreResults = javaScriptCoreTargets.isEmpty ? [:] : unsafe resolveSharedCacheSymbols(
            matching: javaScriptCoreTargets,
            symbols: javaScriptCoreSymbols,
            symbolRange: javaScriptCoreSymbolRange,
            textVMAddress: UInt64(javaScriptCore.text.virtualMemoryAddress),
            textRange: javaScriptCore.textRange,
            slide: javaScriptCore.slide
        )
        return NativeInspectorResolvedSymbolSet(
            connectFrontend: webKitResults[.connectFrontend] ?? .missing,
            disconnectFrontend: webKitResults[.disconnectFrontend] ?? .missing,
            stringFromUTF8: javaScriptCoreResults[.stringFromUTF8] ?? .missing,
            stringImplToNSString: javaScriptCoreResults[.stringImplToNSString] ?? .missing,
            destroyStringImpl: javaScriptCoreResults[.destroyStringImpl] ?? .missing,
            backendDispatcherDispatch: preferredResolvedAddress(
                webKitResults[.backendDispatcherDispatch] ?? .missing,
                fallback: javaScriptCoreResults[.backendDispatcherDispatch] ?? .missing
            )
        )
    }

    private static func sharedCacheTargets(
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        _ targets: [NativeInspectorSymbolMatchTarget]
    ) -> [NativeInspectorSymbolMatchTarget] {
        targets.filter { target in
            guard usesLoadedImageRuntimeFallback(for: target.role) else {
                return true
            }
            return !loadedImageSymbols.address(for: target.role).isFound
        }
    }

    private static func usesLoadedImageRuntimeFallback(for role: NativeInspectorSymbolRole) -> Bool {
        switch role {
        case .stringFromUTF8, .stringImplToNSString, .destroyStringImpl, .backendDispatcherDispatch:
            return true
        case .connectFrontend,
             .disconnectFrontend,
             .inspectorControllerConnectTarget,
             .inspectorControllerDisconnectTarget:
            return false
        }
    }

    @unsafe private static func finalizedSharedCacheResolution(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase,
        sourceBase: String,
        loadedImage: LoadedNativeInspectorImage,
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        runtimeWebKit: NativeInspectorSharedCacheImageContext<MachOImage>,
        runtimeJavaScriptCore: NativeInspectorSharedCacheImageContext<MachOImage>,
        runtimeWebCore: NativeInspectorSharedCacheImageContext<MachOImage>?,
        symbols: NativeInspectorSymbols
    ) -> (lookupResult: NativeInspectorSymbolLookupResult?, resolvedSymbols: NativeInspectorResolvedSymbolSet) {
        let resolvedSymbolsWithFallback = unsafe resolveConnectDisconnectFallbackIfNeeded(
            resolvedSymbols,
            image: runtimeWebKit.image,
            text: runtimeWebKit.text,
            webCoreImage: runtimeWebCore?.image,
            webCoreText: runtimeWebCore?.text,
            javaScriptCoreImage: runtimeJavaScriptCore.image,
            javaScriptCoreText: runtimeJavaScriptCore.text,
            symbols: symbols
        )
        let usedRuntimeFallback = usesLoadedImageRuntimeFallback(
            resolvedSymbols: resolvedSymbolsWithFallback.symbols,
            loadedImageSymbols: loadedImageSymbols
        )
        let resolvedSymbolsWithRuntimeFallback = applyingLoadedImageRuntimeFallback(
            to: resolvedSymbolsWithFallback.symbols,
            loadedImageSymbols: loadedImageSymbols
        )
        let lookupResult = successfulResolutionIfComplete(
            resolvedSymbolsWithRuntimeFallback,
            phase: phase,
            source: sharedCacheSourceDescription(
                base: sourceBase,
                usedConnectDisconnectFallback: resolvedSymbolsWithFallback.usedFallback,
                usedRuntimeFallback: usedRuntimeFallback
            ),
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
            usedConnectDisconnectFallback: resolvedSymbolsWithFallback.usedFallback
        )
        return (lookupResult, resolvedSymbolsWithRuntimeFallback)
    }

    private static func finalizedFileSharedCacheResolution(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase,
        sourceBase: String,
        loadedImage: LoadedNativeInspectorImage,
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet
    ) -> (lookupResult: NativeInspectorSymbolLookupResult?, resolvedSymbols: NativeInspectorResolvedSymbolSet) {
        let usedRuntimeFallback = usesLoadedImageRuntimeFallback(
            resolvedSymbols: resolvedSymbols,
            loadedImageSymbols: loadedImageSymbols
        )
        let resolvedSymbolsWithRuntimeFallback = applyingLoadedImageRuntimeFallback(
            to: resolvedSymbols,
            loadedImageSymbols: loadedImageSymbols
        )
        let lookupResult = successfulResolutionIfComplete(
            resolvedSymbolsWithRuntimeFallback,
            phase: phase,
            source: sharedCacheSourceDescription(
                base: sourceBase,
                usedConnectDisconnectFallback: false,
                usedRuntimeFallback: usedRuntimeFallback
            ),
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
            usedConnectDisconnectFallback: false
        )
        return (lookupResult, resolvedSymbolsWithRuntimeFallback)
    }

    private static func fallbackResolution(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet?,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String,
        loadedImage: LoadedNativeInspectorImage,
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        fallbackFailure: NativeInspectorSymbolLookupFailure
    ) -> NativeInspectorSymbolLookupResult {
        if let resolvedSymbols {
            return finalizeResolution(
                resolvedSymbols,
                phase: phase,
                source: source,
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                usedConnectDisconnectFallback: false
            )
                ?? failure(
                    fallbackFailure.kind,
                    detail: fallbackFailure.detail,
                    phase: phase,
                    source: source,
                    shouldLog: false
                )
        }
        return failure(
            fallbackFailure.kind,
            detail: fallbackFailure.detail,
            phase: phase,
            source: source,
            shouldLog: false
        )
    }
}
#endif

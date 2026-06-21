#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

struct NativeInspectorSymbolMatchTarget {
    let role: NativeInspectorSymbolRole
    let symbol: NativeInspectorRequiredSymbol
}

struct NativeInspectorResolvedSymbolBucket {
    private var candidate: UInt64?
    private var hasMultipleCandidates = false
    var outsideTextAddress: UInt64?

    var isAmbiguous: Bool {
        hasMultipleCandidates
    }

    var resolvedAddress: ResolvedNativeInspectorAddress {
        if hasMultipleCandidates {
            return .ambiguous
        }
        if let candidate {
            return .found(candidate)
        }
        if let outsideTextAddress {
            return .outsideText(outsideTextAddress)
        }
        return .missing
    }

    var needsOutsideTextScan: Bool {
        candidate == nil && outsideTextAddress == nil
    }

    var needsTextCandidateScan: Bool {
        candidate == nil && !hasMultipleCandidates
    }

    mutating func insertCandidate(_ address: UInt64) {
        guard let candidate else {
            self.candidate = address
            return
        }
        if candidate != address {
            hasMultipleCandidates = true
        }
    }
}

private enum NativeInspectorSharedCacheSymbolAddress {
    case text(UInt64)
    case outsideText(UInt64)
    case invalid
}

extension NativeInspectorSymbolResolverCore {
    static func sharedCacheSymbolFileURLs() -> [URL] {
        sharedCacheSymbolFileURLs(activeSharedCachePath: unsafe MachOKitSymbolLookup.hostSharedCachePath)
    }

    static func sharedCacheSymbolFileURLs(activeSharedCachePath: String?) -> [URL] {
        let fileManager = FileManager.default
        var urls = [URL]()
        var seenPaths = Set<String>()

        func appendURL(_ url: URL) {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else {
                return
            }
            urls.append(url)
        }

        if let activeSharedCacheSymbolURL = activeSharedCacheSymbolFileURL(activeSharedCachePath: activeSharedCachePath) {
            appendURL(activeSharedCacheSymbolURL)
        }

        for directoryPath in sharedCacheDirectoryCandidates {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directoryPath) else {
                continue
            }

            let sortedEntries = entries
                .filter { entry in
                    entry.hasPrefix(sharedCacheFilePrefix) && entry.hasSuffix(".symbols")
                }
                .sorted { lhs, rhs in
                    sharedCacheSortKey(for: lhs) < sharedCacheSortKey(for: rhs)
                }

            for entry in sortedEntries {
                appendURL(
                    URL(fileURLWithPath: directoryPath, isDirectory: true)
                        .appendingPathComponent(entry)
                )
            }
        }
        return urls
    }

    static func activeSharedCacheSymbolFileURL(activeSharedCachePath: String?) -> URL? {
        guard let activeSharedCachePath,
              !activeSharedCachePath.isEmpty else {
            return nil
        }

        if activeSharedCachePath.hasSuffix(".symbols") {
            return URL(fileURLWithPath: activeSharedCachePath, isDirectory: false)
        }

        return URL(fileURLWithPath: activeSharedCachePath + ".symbols", isDirectory: false)
    }

    static func sharedCacheSortKey(for fileName: String) -> Int {
        if fileName.contains("arm64e") {
            return 0
        }
        if fileName.contains("arm64") {
            return 1
        }
        return 2
    }

    static func fileBackedLocalSymbols(
        mainCacheHeader: DyldCacheHeader,
        dylibOffset: UInt64
    ) throws -> MachOKitFileBackedLocalSymbols {
        try fileBackedLocalSymbols(
            in: fileBackedLocalSymbolContexts(mainCacheHeader: mainCacheHeader),
            dylibOffset: dylibOffset
        )
    }

    static func fileBackedLocalSymbolContexts(
        mainCacheHeader: DyldCacheHeader
    ) throws -> [NativeInspectorFileBackedLocalSymbolContext] {
        let symbolCacheURLs = sharedCacheSymbolFileURLs()
        guard !symbolCacheURLs.isEmpty else {
            throw NativeInspectorSymbolLookupFailure(
                kind: .localSymbolsUnavailable,
                detail: nil
            )
        }

        var lastFailure: NativeInspectorSymbolLookupFailure?
        var contexts = [NativeInspectorFileBackedLocalSymbolContext]()

        for symbolCacheURL in symbolCacheURLs {
            do {
                let symbolCache = try DyldCache(
                    subcacheUrl: symbolCacheURL,
                    mainCacheHeader: mainCacheHeader
                )
                guard let localSymbolsInfo = symbolCache.localSymbolsInfo else {
                    lastFailure = NativeInspectorSymbolLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: nil
                    )
                    continue
                }
                guard let symbols = localSymbolsInfo.symbols64(in: symbolCache) else {
                    lastFailure = NativeInspectorSymbolLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: nil
                    )
                    continue
                }

                contexts.append(
                    NativeInspectorFileBackedLocalSymbolContext(
                        cache: symbolCache,
                        symbols: symbols,
                        entries: Array(localSymbolsInfo.entries(in: symbolCache))
                    )
                )
            } catch {
                lastFailure = NativeInspectorSymbolLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: nil
                )
            }
        }

        if !contexts.isEmpty {
            return contexts
        }
        throw lastFailure ?? NativeInspectorSymbolLookupFailure(
            kind: .localSymbolsUnavailable,
            detail: nil
        )
    }

    static func fileBackedLocalSymbols(
        in contexts: [NativeInspectorFileBackedLocalSymbolContext],
        dylibOffset: UInt64
    ) throws -> MachOKitFileBackedLocalSymbols {
        var sawSymbolContext = false
        for context in contexts {
            sawSymbolContext = true
            guard let symbolRange = localSymbolRange(
                for: dylibOffset,
                entries: context.entries,
                symbolCount: context.symbols.count
            ) else {
                continue
            }
            return MachOKitFileBackedLocalSymbols(
                symbols: context.symbols,
                symbolRange: symbolRange
            )
        }

        throw NativeInspectorSymbolLookupFailure(
            kind: sawSymbolContext ? .localSymbolEntryMissing : .localSymbolsUnavailable,
            detail: nil
        )
    }

    @unsafe static func resolveSharedCacheSymbol(
        matching requiredSymbol: NativeInspectorRequiredSymbol,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        unsafe resolveSharedCacheSymbols(
            matching: [NativeInspectorSymbolMatchTarget(role: requiredSymbol.role, symbol: requiredSymbol)],
            symbols: symbols,
            symbolRange: symbolRange,
            textVMAddress: textVMAddress,
            textRange: textRange,
            slide: slide
        )[requiredSymbol.role] ?? .missing
    }

    @unsafe static func resolveSharedCacheSymbols(
        matching targets: [NativeInspectorSymbolMatchTarget],
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress] {
        unsafe resolveSharedCacheSymbols(
            matching: targets,
            symbolRange: symbolRange,
            textVMAddress: textVMAddress,
            textRange: textRange,
            slide: slide
        ) { symbolIndex in
            guard symbolIndex >= 0, symbolIndex < symbols.count else {
                return nil
            }
            let symbol = unsafe symbols.symbols.advanced(by: symbolIndex).pointee
            let nameC = unsafe symbols.stringBase.advanced(by: numericCast(symbol.n_un.n_strx))
            let offset = symbols.addressStart + numericCast(symbol.n_value)
            return unsafe (nameC, offset)
        }
    }

    @unsafe static func resolveSharedCacheSymbol(
        matching requiredSymbol: NativeInspectorRequiredSymbol,
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        unsafe resolveSharedCacheSymbols(
            matching: [NativeInspectorSymbolMatchTarget(role: requiredSymbol.role, symbol: requiredSymbol)],
            symbols: symbols,
            symbolRange: symbolRange,
            textVMAddress: textVMAddress,
            textRange: textRange,
            slide: slide
        )[requiredSymbol.role] ?? .missing
    }

    @unsafe static func resolveSharedCacheSymbols(
        matching targets: [NativeInspectorSymbolMatchTarget],
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress] {
        resolveSharedCacheSymbolsByName(
            matching: targets,
            symbols: symbols,
            symbolRange: symbolRange,
            textVMAddress: textVMAddress,
            textRange: textRange,
            slide: slide
        )
    }

    @unsafe private static func resolveSharedCacheSymbols(
        matching targets: [NativeInspectorSymbolMatchTarget],
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64,
        symbolAt symbolAtIndex: (Int) -> (nameC: UnsafePointer<CChar>, offset: Int)?
    ) -> [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress] {
        var buckets = Array(repeating: NativeInspectorResolvedSymbolBucket(), count: targets.count)

        for symbolIndex in symbolRange where buckets.contains(where: { !$0.isAmbiguous }) {
            guard let symbol = unsafe symbolAtIndex(symbolIndex) else {
                continue
            }
            let symbolOffset = unsafe symbol.offset
            guard case let .text(address) = sharedCacheSymbolAddress(
                offset: symbolOffset,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            ) else {
                continue
            }

            let variants = unsafe NativeInspectorSymbolName.variants(for: symbol.nameC)

            for targetIndex in targets.indices {
                guard !buckets[targetIndex].isAmbiguous,
                      unsafe targets[targetIndex].symbol.matches(cStringVariants: variants) else {
                    continue
                }
                buckets[targetIndex].insertCandidate(address)
            }
        }

        for symbolIndex in symbolRange where buckets.contains(where: \.needsOutsideTextScan) {
            guard let symbol = unsafe symbolAtIndex(symbolIndex) else {
                continue
            }
            let symbolOffset = unsafe symbol.offset
            guard case let .outsideText(address) = sharedCacheSymbolAddress(
                offset: symbolOffset,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            ) else {
                continue
            }

            let variants = unsafe NativeInspectorSymbolName.variants(for: symbol.nameC)

            for targetIndex in targets.indices {
                guard buckets[targetIndex].needsOutsideTextScan,
                      unsafe targets[targetIndex].symbol.matches(cStringVariants: variants) else {
                    continue
                }
                var bucket = buckets[targetIndex]
                bucket.outsideTextAddress = address
                buckets[targetIndex] = bucket
            }
        }

        var resolvedSymbols = [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress]()
        resolvedSymbols.reserveCapacity(targets.count)
        for targetIndex in targets.indices {
            resolvedSymbols[targets[targetIndex].role] = buckets[targetIndex].resolvedAddress
        }
        return resolvedSymbols
    }

    private static func resolveSharedCacheSymbolsByName(
        matching targets: [NativeInspectorSymbolMatchTarget],
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress] {
        var buckets = Array(repeating: NativeInspectorResolvedSymbolBucket(), count: targets.count)

        for symbolIndex in symbolRange where buckets.contains(where: { !$0.isAmbiguous }) {
            let symbol = symbols[symbolIndex]
            guard case let .text(address) = sharedCacheSymbolAddress(
                offset: symbol.offset,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            ) else {
                continue
            }

            var variants: NativeInspectorSymbolName.Variants?

            for targetIndex in targets.indices {
                guard !buckets[targetIndex].isAmbiguous,
                      targets[targetIndex].symbol.mayMatch(rawSymbolName: symbol.name) else {
                    continue
                }

                let symbolVariants: NativeInspectorSymbolName.Variants
                if let variants {
                    symbolVariants = variants
                } else {
                    let resolvedVariants = NativeInspectorSymbolName.variants(for: symbol.name)
                    variants = resolvedVariants
                    symbolVariants = resolvedVariants
                }

                guard targets[targetIndex].symbol.matches(
                    variants: symbolVariants,
                    checkingRawNameNeedle: false
                ) else {
                    continue
                }
                buckets[targetIndex].insertCandidate(address)
            }
        }

        for symbolIndex in symbolRange where buckets.contains(where: \.needsOutsideTextScan) {
            let symbol = symbols[symbolIndex]
            guard case let .outsideText(address) = sharedCacheSymbolAddress(
                offset: symbol.offset,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            ) else {
                continue
            }

            var variants: NativeInspectorSymbolName.Variants?

            for targetIndex in targets.indices {
                guard buckets[targetIndex].needsOutsideTextScan,
                      targets[targetIndex].symbol.mayMatch(rawSymbolName: symbol.name) else {
                    continue
                }

                let symbolVariants: NativeInspectorSymbolName.Variants
                if let variants {
                    symbolVariants = variants
                } else {
                    let resolvedVariants = NativeInspectorSymbolName.variants(for: symbol.name)
                    variants = resolvedVariants
                    symbolVariants = resolvedVariants
                }

                guard targets[targetIndex].symbol.matches(
                    variants: symbolVariants,
                    checkingRawNameNeedle: false
                ) else {
                    continue
                }
                buckets[targetIndex].outsideTextAddress = address
            }
        }

        var resolvedSymbols = [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress]()
        resolvedSymbols.reserveCapacity(targets.count)
        for targetIndex in targets.indices {
            resolvedSymbols[targets[targetIndex].role] = buckets[targetIndex].resolvedAddress
        }
        return resolvedSymbols
    }

    private static func sharedCacheSymbolAddress(
        offset: Int,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> NativeInspectorSharedCacheSymbolAddress {
        guard offset >= 0 else {
            return .invalid
        }

        let unslidAddress = UInt64(offset)
        let actualAddress = slide + unslidAddress
        guard unslidAddress >= textVMAddress else {
            return .outsideText(actualAddress)
        }

        let offsetWithinText = unslidAddress - textVMAddress
        let resolvedAddress = textRange.lowerBound + offsetWithinText
        guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
            return .outsideText(actualAddress)
        }
        return .text(actualAddress)
    }

    private static func appendSharedCacheSymbolAddress(
        offset: Int,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64,
        candidates: inout Set<UInt64>,
        outsideTextAddress: inout UInt64?
    ) {
        guard offset >= 0 else {
            return
        }

        let unslidAddress = UInt64(offset)
        let actualAddress = slide + unslidAddress
        guard unslidAddress >= textVMAddress else {
            if outsideTextAddress == nil {
                outsideTextAddress = actualAddress
            }
            return
        }

        let offsetWithinText = unslidAddress - textVMAddress
        let resolvedAddress = textRange.lowerBound + offsetWithinText
        guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
            if outsideTextAddress == nil {
                outsideTextAddress = actualAddress
            }
            return
        }
        candidates.insert(actualAddress)
    }
}
#endif

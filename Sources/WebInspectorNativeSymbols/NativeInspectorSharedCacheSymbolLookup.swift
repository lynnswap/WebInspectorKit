#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

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

    static func resolveSharedCacheSymbol(
        matching requiredSymbol: NativeInspectorRequiredSymbol,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        var candidates = Set<UInt64>()
        var outsideTextAddress: UInt64?

        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard requiredSymbol.matches(symbolName: symbol.name) else {
                continue
            }
            appendSharedCacheSymbolAddress(
                offset: symbol.offset,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide,
                candidates: &candidates,
                outsideTextAddress: &outsideTextAddress
            )
        }

        return resolvedAddress(from: candidates, outsideTextAddress: outsideTextAddress)
    }

    static func resolveSharedCacheSymbol(
        matching requiredSymbol: NativeInspectorRequiredSymbol,
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        var candidates = Set<UInt64>()
        var outsideTextAddress: UInt64?

        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard requiredSymbol.matches(symbolName: symbol.name) else {
                continue
            }
            appendSharedCacheSymbolAddress(
                offset: symbol.offset,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide,
                candidates: &candidates,
                outsideTextAddress: &outsideTextAddress
            )
        }

        return resolvedAddress(from: candidates, outsideTextAddress: outsideTextAddress)
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

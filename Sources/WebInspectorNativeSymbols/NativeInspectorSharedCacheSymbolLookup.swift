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
            return URL(fileURLWithPath: activeSharedCachePath)
        }

        return URL(fileURLWithPath: activeSharedCachePath + ".symbols")
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
        let symbolCacheURLs = sharedCacheSymbolFileURLs()
        guard !symbolCacheURLs.isEmpty else {
            throw NativeInspectorSymbolLookupFailure(
                kind: .localSymbolsUnavailable,
                detail: nil
            )
        }

        var lastFailure: NativeInspectorSymbolLookupFailure?

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
                guard let entry = localSymbolsInfo.entries(in: symbolCache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
                    lastFailure = NativeInspectorSymbolLookupFailure(
                        kind: .localSymbolEntryMissing,
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

                return MachOKitFileBackedLocalSymbols(
                    symbols: symbols,
                    symbolRange: entry.nlistRange
                )
            } catch {
                lastFailure = NativeInspectorSymbolLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: nil
                )
            }
        }

        throw lastFailure ?? NativeInspectorSymbolLookupFailure(
            kind: .localSymbolsUnavailable,
            detail: nil
        )
    }

    static func resolveSharedCacheSymbol(
        named symbolName: String,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName else {
                continue
            }
            guard symbol.offset >= 0 else {
                return .missing
            }

            let unslidAddress = UInt64(symbol.offset)
            let actualAddress = slide + unslidAddress
            guard unslidAddress >= textVMAddress else {
                return .outsideText(actualAddress)
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
                return .outsideText(actualAddress)
            }
            return .found(actualAddress)
        }

        return .missing
    }

    static func resolveSharedCacheSymbol(
        named symbolName: String,
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName else {
                continue
            }
            guard symbol.offset >= 0 else {
                return .missing
            }

            let unslidAddress = UInt64(symbol.offset)
            let actualAddress = slide + unslidAddress
            guard unslidAddress >= textVMAddress else {
                return .outsideText(actualAddress)
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
                return .outsideText(actualAddress)
            }
            return .found(actualAddress)
        }

        return .missing
    }
}
#endif

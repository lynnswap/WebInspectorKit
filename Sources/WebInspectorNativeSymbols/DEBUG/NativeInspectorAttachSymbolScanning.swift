#if DEBUG
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    @unsafe static func debugSimilarLoadedImageAttachSymbols(
        source: String,
        imageName: String,
        image: MachOImage,
        text: SegmentCommand64
    ) -> NativeInspectorAttachSymbolScan {
        var scan = NativeInspectorAttachSymbolScan()
        let imageBaseAddress = unsafe UInt64(UInt(bitPattern: image.ptr))
        for symbol in image.symbols {
            scan.scannedCount += 1
            let name = symbol.name
            guard debugAttachSymbolNamePassesPrefilter(name) else {
                continue
            }
            scan.matchedCount += 1
            guard symbol.offset >= 0 else {
                continue
            }
            let offset = UInt64(symbol.offset)
            guard offset < UInt64(text.virtualMemorySize) else {
                continue
            }
            let address = imageBaseAddress + offset
            if let candidate = debugAttachSymbolCandidate(
                name: name,
                address: address,
                source: source,
                imageName: imageName
            ) {
                debugAppendTopAttachSymbolCandidate(candidate, to: &scan.candidates)
            }
        }
        return scan
    }

    @unsafe static func debugSimilarLoadedImageExportAttachSymbols(
        source: String,
        imageName: String,
        image: MachOImage,
        text: SegmentCommand64
    ) -> NativeInspectorAttachSymbolScan {
        var scan = NativeInspectorAttachSymbolScan()
        let imageBaseAddress = unsafe UInt64(UInt(bitPattern: image.ptr))
        for symbol in image.exportedSymbols {
            scan.scannedCount += 1
            let name = symbol.name
            guard debugAttachSymbolNamePassesPrefilter(name) else {
                continue
            }
            scan.matchedCount += 1
            guard let symbolOffset = symbol.offset,
                  symbolOffset >= 0 else {
                continue
            }
            let offset = UInt64(symbolOffset)
            guard offset < UInt64(text.virtualMemorySize) else {
                continue
            }
            let address = imageBaseAddress + offset
            if let candidate = debugAttachSymbolCandidate(
                name: name,
                address: address,
                source: source,
                imageName: imageName
            ) {
                debugAppendTopAttachSymbolCandidate(candidate, to: &scan.candidates)
            }
        }
        return scan
    }

    @unsafe static func debugSimilarSharedCacheAttachSymbols(
        loadedWebKitHeaderAddress: UInt,
        loadedWebCoreHeaderAddress: UInt?,
        imagePathSuffixes: [String]
    ) -> [NativeInspectorAttachSymbolScan] {
        guard let cache = unsafe MachOKitSymbolLookup.currentSharedCache,
              let slide = cache.slide,
              slide >= 0,
              let webKitImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: imagePathSuffixes) }),
              webKitImage.is64Bit,
              let webKitText = textSegment(in: webKitImage) else {
            return []
        }

        var scans = [NativeInspectorAttachSymbolScan]()
        let unsignedSlide = UInt64(slide)
        let webKitTextRange = UInt64(loadedWebKitHeaderAddress) ..< UInt64(loadedWebKitHeaderAddress) + UInt64(webKitText.virtualMemorySize)
        let webKitDylibOffset = UInt64(webKitText.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart

        let webCoreImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: webCoreImagePathSuffixes) })
        let webCoreText = webCoreImage.flatMap { $0.is64Bit ? textSegment(in: $0) : nil }
        let webCoreContext: (image: MachOImage, text: SegmentCommand64, textRange: Range<UInt64>, dylibOffset: UInt64)?
        if let webCoreImage,
           let webCoreText,
           let loadedWebCoreHeaderAddress {
            webCoreContext = (
                image: webCoreImage,
                text: webCoreText,
                textRange: UInt64(loadedWebCoreHeaderAddress) ..< UInt64(loadedWebCoreHeaderAddress) + UInt64(webCoreText.virtualMemorySize),
                dylibOffset: UInt64(webCoreText.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
            )
        } else {
            webCoreContext = nil
        }

        if let localSymbolsInfo = cache.localSymbolsInfo,
           let symbols64 = localSymbolsInfo.symbols64(in: cache) {
            let entries = localSymbolsInfo.entries(in: cache)
            if let entry = entries.first(where: { UInt64($0.dylibOffset) == webKitDylibOffset }) {
                let symbolRange = entry.nlistStartIndex ..< entry.nlistStartIndex + entry.nlistCount
                if symbolRange.lowerBound >= 0, symbolRange.upperBound <= symbols64.count {
                    scans.append(debugSimilarSharedCacheAttachSymbols(
                        source: "shared-cache",
                        imageName: "WebKit",
                        symbols: symbols64,
                        symbolRange: symbolRange,
                        textVMAddress: UInt64(webKitText.virtualMemoryAddress),
                        textRange: webKitTextRange,
                        slide: unsignedSlide
                    ))
                }
            }
            if let webCoreContext,
               let entry = entries.first(where: { UInt64($0.dylibOffset) == webCoreContext.dylibOffset }) {
                let symbolRange = entry.nlistStartIndex ..< entry.nlistStartIndex + entry.nlistCount
                if symbolRange.lowerBound >= 0, symbolRange.upperBound <= symbols64.count {
                    scans.append(debugSimilarSharedCacheAttachSymbols(
                        source: "shared-cache",
                        imageName: "WebCore",
                        symbols: symbols64,
                        symbolRange: symbolRange,
                        textVMAddress: UInt64(webCoreContext.text.virtualMemoryAddress),
                        textRange: webCoreContext.textRange,
                        slide: unsignedSlide
                    ))
                }
            }
        }

        if let fileBackedSymbols = try? fileBackedLocalSymbols(
            mainCacheHeader: cache.mainCacheHeader,
            dylibOffset: webKitDylibOffset
        ) {
            scans.append(debugSimilarSharedCacheAttachSymbols(
                source: "shared-cache-file",
                imageName: "WebKit",
                symbols: fileBackedSymbols.symbols,
                symbolRange: fileBackedSymbols.symbolRange,
                textVMAddress: UInt64(webKitText.virtualMemoryAddress),
                textRange: webKitTextRange,
                slide: unsignedSlide
            ))
        }
        if let webCoreContext,
           let fileBackedSymbols = try? fileBackedLocalSymbols(
                mainCacheHeader: cache.mainCacheHeader,
                dylibOffset: webCoreContext.dylibOffset
           ) {
            scans.append(debugSimilarSharedCacheAttachSymbols(
                source: "shared-cache-file",
                imageName: "WebCore",
                symbols: fileBackedSymbols.symbols,
                symbolRange: fileBackedSymbols.symbolRange,
                textVMAddress: UInt64(webCoreContext.text.virtualMemoryAddress),
                textRange: webCoreContext.textRange,
                slide: unsignedSlide
            ))
        }

        return scans
    }

    static func debugSimilarSharedCacheAttachSymbols(
        source: String,
        imageName: String,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> NativeInspectorAttachSymbolScan {
        var scan = NativeInspectorAttachSymbolScan()
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            debugScanSharedCacheAttachSymbol(
                name: symbol.name,
                offset: symbol.offset,
                source: source,
                imageName: imageName,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide,
                scan: &scan
            )
        }
        return scan
    }

    static func debugSimilarSharedCacheAttachSymbols(
        source: String,
        imageName: String,
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> NativeInspectorAttachSymbolScan {
        var scan = NativeInspectorAttachSymbolScan()
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            debugScanSharedCacheAttachSymbol(
                name: symbol.name,
                offset: symbol.offset,
                source: source,
                imageName: imageName,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide,
                scan: &scan
            )
        }
        return scan
    }

    static func debugScanSharedCacheAttachSymbol(
        name: String,
        offset: Int,
        source: String,
        imageName: String,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64,
        scan: inout NativeInspectorAttachSymbolScan
    ) {
        scan.scannedCount += 1
        guard debugAttachSymbolNamePassesPrefilter(name) else {
            return
        }
        scan.matchedCount += 1
        guard offset >= 0 else {
            return
        }

        let unslidAddress = UInt64(offset)
        guard unslidAddress >= textVMAddress else {
            return
        }
        let actualAddress = slide + unslidAddress
        let offsetWithinText = unslidAddress - textVMAddress
        let resolvedAddress = textRange.lowerBound + offsetWithinText
        guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
            return
        }

        if let candidate = debugAttachSymbolCandidate(
            name: name,
            address: actualAddress,
            source: source,
            imageName: imageName
        ) {
            debugAppendTopAttachSymbolCandidate(candidate, to: &scan.candidates)
        }
    }
}
#endif

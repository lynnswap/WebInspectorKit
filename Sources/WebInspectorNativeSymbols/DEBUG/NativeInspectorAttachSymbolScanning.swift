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
        loadedWebKitImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedWebCoreImage: LoadedNativeInspectorImage?,
        webCorePathSuffixes: [String]
    ) -> [NativeInspectorAttachSymbolScan] {
        var scans = [NativeInspectorAttachSymbolScan]()
        if let context = unsafe loadedSharedCacheContext(
            loadedImage: loadedWebKitImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes
        ) {
            appendDebugSharedCacheAttachScans(
                webKit: context.webKit,
                webCore: context.webCore,
                symbols64: context.localSymbols,
                entries: context.localSymbolEntries,
                source: "shared-cache",
                scans: &scans
            )
            if let fileBackedContexts = try? fileBackedLocalSymbolContexts(
                mainCacheHeader: context.cache.mainCacheHeader
            ) {
                appendDebugFileBackedSharedCacheAttachScans(
                    webKit: context.webKit,
                    webCore: context.webCore,
                    fileBackedContexts: fileBackedContexts,
                    source: "shared-cache-file",
                    scans: &scans
                )
            }
        }

        if let context = unsafe fullSharedCacheContext(
            loadedImage: loadedWebKitImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes
        ) {
            appendDebugSharedCacheAttachScans(
                webKit: context.webKit,
                webCore: context.webCore,
                symbols64: context.localSymbols,
                entries: context.localSymbolEntries,
                source: "full-cache",
                scans: &scans
            )
            if let fileBackedContexts = try? fileBackedLocalSymbolContexts(
                mainCacheHeader: context.cache.mainCacheHeader
            ) {
                appendDebugFileBackedSharedCacheAttachScans(
                    webKit: context.webKit,
                    webCore: context.webCore,
                    fileBackedContexts: fileBackedContexts,
                    source: "full-cache-file",
                    scans: &scans
                )
            }
        }

        return scans
    }

    static func appendDebugSharedCacheAttachScans(
        webKit: NativeInspectorSharedCacheImageContext<MachOImage>,
        webCore: NativeInspectorSharedCacheImageContext<MachOImage>?,
        symbols64: MachOImage.Symbols64?,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        source: String,
        scans: inout [NativeInspectorAttachSymbolScan]
    ) {
        guard let symbols64 else {
            return
        }
        appendDebugSharedCacheAttachScan(
            context: webKit,
            imageName: "WebKit",
            symbols: symbols64,
            entries: entries,
            source: source,
            scans: &scans
        )
        if let webCore {
            appendDebugSharedCacheAttachScan(
                context: webCore,
                imageName: "WebCore",
                symbols: symbols64,
                entries: entries,
                source: source,
                scans: &scans
            )
        }
    }

    static func appendDebugSharedCacheAttachScans(
        webKit: NativeInspectorSharedCacheImageContext<MachOFile>,
        webCore: NativeInspectorSharedCacheImageContext<MachOFile>?,
        symbols64: MachOFile.Symbols64?,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        source: String,
        scans: inout [NativeInspectorAttachSymbolScan]
    ) {
        guard let symbols64 else {
            return
        }
        appendDebugSharedCacheAttachScan(
            context: webKit,
            imageName: "WebKit",
            symbols: symbols64,
            entries: entries,
            source: source,
            scans: &scans
        )
        if let webCore {
            appendDebugSharedCacheAttachScan(
                context: webCore,
                imageName: "WebCore",
                symbols: symbols64,
                entries: entries,
                source: source,
                scans: &scans
            )
        }
    }

    static func appendDebugSharedCacheAttachScan(
        context: NativeInspectorSharedCacheImageContext<MachOImage>,
        imageName: String,
        symbols: MachOImage.Symbols64,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        source: String,
        scans: inout [NativeInspectorAttachSymbolScan]
    ) {
        guard let symbolRange = localSymbolRange(
            for: context.dylibOffset,
            entries: entries,
            symbolCount: symbols.count
        ) else {
            return
        }
        scans.append(debugSimilarSharedCacheAttachSymbols(
            source: source,
            imageName: imageName,
            symbols: symbols,
            symbolRange: symbolRange,
            textVMAddress: UInt64(context.text.virtualMemoryAddress),
            textRange: context.textRange,
            slide: context.slide
        ))
    }

    static func appendDebugSharedCacheAttachScan(
        context: NativeInspectorSharedCacheImageContext<MachOFile>,
        imageName: String,
        symbols: MachOFile.Symbols64,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        source: String,
        scans: inout [NativeInspectorAttachSymbolScan]
    ) {
        guard let symbolRange = localSymbolRange(
            for: context.dylibOffset,
            entries: entries,
            symbolCount: symbols.count
        ) else {
            return
        }
        scans.append(debugSimilarSharedCacheAttachSymbols(
            source: source,
            imageName: imageName,
            symbols: symbols,
            symbolRange: symbolRange,
            textVMAddress: UInt64(context.text.virtualMemoryAddress),
            textRange: context.textRange,
            slide: context.slide
        ))
    }

    static func appendDebugFileBackedSharedCacheAttachScans<Image>(
        webKit: NativeInspectorSharedCacheImageContext<Image>,
        webCore: NativeInspectorSharedCacheImageContext<Image>?,
        fileBackedContexts: [NativeInspectorFileBackedLocalSymbolContext],
        source: String,
        scans: inout [NativeInspectorAttachSymbolScan]
    ) {
        appendDebugFileBackedSharedCacheAttachScan(
            context: webKit,
            imageName: "WebKit",
            fileBackedContexts: fileBackedContexts,
            source: source,
            scans: &scans
        )
        if let webCore {
            appendDebugFileBackedSharedCacheAttachScan(
                context: webCore,
                imageName: "WebCore",
                fileBackedContexts: fileBackedContexts,
                source: source,
                scans: &scans
            )
        }
    }

    static func appendDebugFileBackedSharedCacheAttachScan<Image>(
        context: NativeInspectorSharedCacheImageContext<Image>,
        imageName: String,
        fileBackedContexts: [NativeInspectorFileBackedLocalSymbolContext],
        source: String,
        scans: inout [NativeInspectorAttachSymbolScan]
    ) {
        guard let fileBackedSymbols = try? fileBackedLocalSymbols(
            in: fileBackedContexts,
            dylibOffset: context.dylibOffset
        ) else {
            return
        }
        scans.append(debugSimilarSharedCacheAttachSymbols(
            source: source,
            imageName: imageName,
            symbols: fileBackedSymbols.symbols,
            symbolRange: fileBackedSymbols.symbolRange,
            textVMAddress: UInt64(context.text.virtualMemoryAddress),
            textRange: context.textRange,
            slide: context.slide
        ))
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

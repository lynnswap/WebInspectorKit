#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

struct NativeInspectorSharedCacheImageContext<Image> {
    let image: Image
    let text: SegmentCommand64
    let textRange: Range<UInt64>
    let dylibOffset: UInt64
    let slide: UInt64
}

struct NativeInspectorLoadedSharedCacheContext {
    let cache: DyldCacheLoaded
    let webKit: NativeInspectorSharedCacheImageContext<MachOImage>
    let javaScriptCore: NativeInspectorSharedCacheImageContext<MachOImage>
    let webCore: NativeInspectorSharedCacheImageContext<MachOImage>?
    let localSymbols: MachOImage.Symbols64?
    let localSymbolEntries: [any DyldCacheLocalSymbolsEntryProtocol]
}

struct NativeInspectorFullSharedCacheContext {
    let cache: FullDyldCache
    let webKit: NativeInspectorSharedCacheImageContext<MachOFile>
    let javaScriptCore: NativeInspectorSharedCacheImageContext<MachOFile>
    let webCore: NativeInspectorSharedCacheImageContext<MachOFile>?
    let localSymbols: MachOFile.Symbols64?
    let localSymbolEntries: [any DyldCacheLocalSymbolsEntryProtocol]
}

struct NativeInspectorFileBackedLocalSymbolContext {
    let cache: DyldCache
    let symbols: MachOFile.Symbols64
    let entries: [any DyldCacheLocalSymbolsEntryProtocol]
}

extension NativeInspectorSymbolResolverCore {
    @unsafe static func loadedSharedCacheContext(
        loadedImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedWebCoreImage: LoadedNativeInspectorImage?,
        webCorePathSuffixes: [String]
    ) -> NativeInspectorLoadedSharedCacheContext? {
        guard let cache = unsafe MachOKitSymbolLookup.currentSharedCache,
              let slide = cache.slide,
              slide >= 0 else {
            return nil
        }

        let images = Array(cache.machOImages())
        guard let webKitImage = images.first(where: { imagePathMatches($0.path, suffixes: imagePathSuffixes) }),
              let javaScriptCoreImage = images.first(where: { imagePathMatches($0.path, suffixes: javaScriptCorePathSuffixes) }),
              let webKitContext = sharedCacheImageContext(
                image: webKitImage,
                loadedHeaderAddress: loadedImage.headerAddress,
                mainCacheHeader: cache.mainCacheHeader,
                slide: UInt64(slide)
              ),
              let javaScriptCoreContext = sharedCacheImageContext(
                image: javaScriptCoreImage,
                loadedHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                mainCacheHeader: cache.mainCacheHeader,
                slide: UInt64(slide)
              ) else {
            return nil
        }

        let webCoreContext: NativeInspectorSharedCacheImageContext<MachOImage>?
        if let loadedWebCoreImage,
           let webCoreImage = images.first(where: { imagePathMatches($0.path, suffixes: webCorePathSuffixes) }) {
            webCoreContext = sharedCacheImageContext(
                image: webCoreImage,
                loadedHeaderAddress: loadedWebCoreImage.headerAddress,
                mainCacheHeader: cache.mainCacheHeader,
                slide: UInt64(slide)
            )
        } else {
            webCoreContext = nil
        }

        let localSymbolsInfo = cache.localSymbolsInfo
        return NativeInspectorLoadedSharedCacheContext(
            cache: cache,
            webKit: webKitContext,
            javaScriptCore: javaScriptCoreContext,
            webCore: webCoreContext,
            localSymbols: localSymbolsInfo?.symbols64(in: cache),
            localSymbolEntries: localSymbolsInfo.map { Array($0.entries(in: cache)) } ?? []
        )
    }

    @unsafe static func fullSharedCacheContext(
        loadedImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedWebCoreImage: LoadedNativeInspectorImage?,
        webCorePathSuffixes: [String]
    ) -> NativeInspectorFullSharedCacheContext? {
        guard let cache = unsafe MachOKitSymbolLookup.hostFullSharedCache else {
            return nil
        }

        let files = Array(cache.machOFiles())
        guard let webKitFile = files.first(where: { imagePathMatches($0.imagePath, suffixes: imagePathSuffixes) }),
              let javaScriptCoreFile = files.first(where: { imagePathMatches($0.imagePath, suffixes: javaScriptCorePathSuffixes) }),
              let webKitContext = sharedCacheImageContext(
                image: webKitFile,
                loadedHeaderAddress: loadedImage.headerAddress,
                mainCacheHeader: cache.mainCacheHeader
              ),
              let javaScriptCoreContext = sharedCacheImageContext(
                image: javaScriptCoreFile,
                loadedHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                mainCacheHeader: cache.mainCacheHeader
              ) else {
            return nil
        }

        let webCoreContext: NativeInspectorSharedCacheImageContext<MachOFile>?
        if let loadedWebCoreImage,
           let webCoreFile = files.first(where: { imagePathMatches($0.imagePath, suffixes: webCorePathSuffixes) }) {
            webCoreContext = sharedCacheImageContext(
                image: webCoreFile,
                loadedHeaderAddress: loadedWebCoreImage.headerAddress,
                mainCacheHeader: cache.mainCacheHeader
            )
        } else {
            webCoreContext = nil
        }

        let localSymbolsInfo = cache.localSymbolsInfo
        return NativeInspectorFullSharedCacheContext(
            cache: cache,
            webKit: webKitContext,
            javaScriptCore: javaScriptCoreContext,
            webCore: webCoreContext,
            localSymbols: localSymbolsInfo?.symbols64(in: cache),
            localSymbolEntries: localSymbolsInfo.map { Array($0.entries(in: cache)) } ?? []
        )
    }

    static func sharedCacheImageContext(
        image: MachOImage,
        loadedHeaderAddress: UInt,
        mainCacheHeader: DyldCacheHeader,
        slide: UInt64
    ) -> NativeInspectorSharedCacheImageContext<MachOImage>? {
        guard image.is64Bit,
              let text = textSegment(in: image) else {
            return nil
        }
        let textStart = UInt64(loadedHeaderAddress)
        let textRange = textStart ..< textStart + UInt64(text.virtualMemorySize)
        return NativeInspectorSharedCacheImageContext(
            image: image,
            text: text,
            textRange: textRange,
            dylibOffset: UInt64(text.virtualMemoryAddress) - mainCacheHeader.sharedRegionStart,
            slide: slide
        )
    }

    static func sharedCacheImageContext(
        image: MachOFile,
        loadedHeaderAddress: UInt,
        mainCacheHeader: DyldCacheHeader
    ) -> NativeInspectorSharedCacheImageContext<MachOFile>? {
        guard image.is64Bit,
              let text = textSegment(in: image) else {
            return nil
        }
        let textStart = UInt64(loadedHeaderAddress)
        let textRange = textStart ..< textStart + UInt64(text.virtualMemorySize)
        return NativeInspectorSharedCacheImageContext(
            image: image,
            text: text,
            textRange: textRange,
            dylibOffset: UInt64(text.virtualMemoryAddress) - mainCacheHeader.sharedRegionStart,
            slide: textStart - UInt64(text.virtualMemoryAddress)
        )
    }

    static func localSymbolRange(
        for dylibOffset: UInt64,
        entries: [any DyldCacheLocalSymbolsEntryProtocol],
        symbolCount: Int
    ) -> Range<Int>? {
        guard let entry = entries.first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
            return nil
        }
        let lowerBound = entry.nlistStartIndex
        let upperBound = lowerBound + entry.nlistCount
        guard lowerBound >= 0,
              upperBound >= lowerBound,
              upperBound <= symbolCount else {
            return nil
        }
        return lowerBound ..< upperBound
    }
}
#endif

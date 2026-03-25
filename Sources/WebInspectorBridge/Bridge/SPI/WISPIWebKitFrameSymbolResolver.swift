#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

@unsafe package struct WISPIWebKitFrameSymbols {
    package typealias WKTypeRefRaw = UnsafeRawPointer
    package typealias WKPageRefRaw = UnsafeRawPointer
    package typealias WKFrameHandleRefRaw = UnsafeRawPointer
    package typealias WKFrameRefRaw = UnsafeRawPointer
    package typealias WKURLRefRaw = UnsafeRawPointer
    package typealias WKStringRefRaw = UnsafeRawPointer
    package typealias WKDataRefRaw = UnsafeRawPointer
    package typealias WKErrorRefRaw = UnsafeRawPointer

    package typealias FrameGetResourceDataCallback = @convention(c) (WKDataRefRaw?, WKErrorRefRaw?, UnsafeMutableRawPointer?) -> Void

    package let pageLookUpFrameFromHandle: @convention(c) (WKPageRefRaw?, WKFrameHandleRefRaw?) -> WKFrameRefRaw?
    package let frameCopyURL: @convention(c) (WKFrameRefRaw?) -> WKURLRefRaw?
    package let frameCopyMIMEType: @convention(c) (WKFrameRefRaw?) -> WKStringRefRaw?
    package let frameIsDisplayingStandaloneImageDocument: @convention(c) (WKFrameRefRaw?) -> Bool
    package let frameGetMainResourceData: @convention(c) (WKFrameRefRaw?, FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void
    package let frameGetResourceData: @convention(c) (WKFrameRefRaw?, WKURLRefRaw?, FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void
    package let urlCreateWithUTF8String: @convention(c) (UnsafePointer<CChar>?, Int) -> WKURLRefRaw?
    package let urlCopyString: @convention(c) (WKURLRefRaw?) -> WKStringRefRaw?
    package let dataGetBytes: @convention(c) (WKDataRefRaw?) -> UnsafePointer<UInt8>?
    package let dataGetSize: @convention(c) (WKDataRefRaw?) -> Int
    package let stringGetMaximumUTF8CStringSize: @convention(c) (WKStringRefRaw?) -> Int
    package let stringGetUTF8CString: @convention(c) (WKStringRefRaw?, UnsafeMutablePointer<CChar>?, Int) -> Int
    package let errorCopyDomain: @convention(c) (WKErrorRefRaw?) -> WKStringRefRaw?
    package let errorGetErrorCode: @convention(c) (WKErrorRefRaw?) -> Int32
    package let errorCopyLocalizedDescription: @convention(c) (WKErrorRefRaw?) -> WKStringRefRaw?
    package let release: @convention(c) (WKTypeRefRaw?) -> Void
}

@unsafe package enum WISPIWebKitFrameSymbolResolver {
    private static let webKitImagePathSuffixes = [
        "/System/Library/Frameworks/WebKit.framework/WebKit",
        "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
    ]
    private static let textSegmentName = "__TEXT"

    private static let symbolNames: [String] = [
        "_WKPageLookUpFrameFromHandle",
        "_WKFrameCopyURL",
        "_WKFrameCopyMIMEType",
        "_WKFrameIsDisplayingStandaloneImageDocument",
        "_WKFrameGetMainResourceData",
        "_WKFrameGetResourceData",
        "_WKURLCreateWithUTF8String",
        "_WKURLCopyString",
        "_WKDataGetBytes",
        "_WKDataGetSize",
        "_WKStringGetMaximumUTF8CStringSize",
        "_WKStringGetUTF8CString",
        "_WKErrorCopyDomain",
        "_WKErrorGetErrorCode",
        "_WKErrorCopyLocalizedDescription",
        "_WKRelease",
    ]

    private static let cachedSymbols = unsafe resolve()

    package static func symbols() -> WISPIWebKitFrameSymbols? {
        cachedSymbols
    }

    private static func resolve() -> WISPIWebKitFrameSymbols? {
        guard let loadedImage = loadedWebKitImage(),
              let loadedTextSegment = textSegment(in: loadedImage) else {
            return nil
        }

        let cache = DyldCacheLoaded.current
        let cacheImage = cache?.machOImages().first(where: { imagePathMatches($0.path) })
        let cacheTextSegment = cacheImage.flatMap(textSegment(in:))

        func resolvedFunction<T>(named symbolName: String, as _: T.Type) -> T? {
            if let address = resolveLoadedImageSymbol(named: symbolName, in: loadedImage, text: loadedTextSegment) {
                return unsafe unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(address)), to: T.self)
            }
            if let cache,
               let cacheImage,
               let cacheTextSegment,
               let address = resolveSharedCacheSymbol(
                named: symbolName,
                in: cacheImage,
                text: cacheTextSegment,
                cache: cache
               ) {
                return unsafe unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(address)), to: T.self)
            }
            return nil
        }

        guard
            let pageLookUpFrameFromHandle: (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[0], as: ((@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> UnsafeRawPointer?).self)),
            let frameCopyURL: (@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[1], as: ((@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?).self)),
            let frameCopyMIMEType: (@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[2], as: ((@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?).self)),
            let frameIsDisplayingStandaloneImageDocument: (@convention(c) (UnsafeRawPointer?) -> Bool) = resolvedFunction(named: symbolNames[3], as: ((@convention(c) (UnsafeRawPointer?) -> Bool).self)),
            let frameGetMainResourceData: (@convention(c) (UnsafeRawPointer?, WISPIWebKitFrameSymbols.FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void) = resolvedFunction(named: symbolNames[4], as: ((@convention(c) (UnsafeRawPointer?, WISPIWebKitFrameSymbols.FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void).self)),
            let frameGetResourceData: (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, WISPIWebKitFrameSymbols.FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void) = resolvedFunction(named: symbolNames[5], as: ((@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, WISPIWebKitFrameSymbols.FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void).self)),
            let urlCreateWithUTF8String: (@convention(c) (UnsafePointer<CChar>?, Int) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[6], as: ((@convention(c) (UnsafePointer<CChar>?, Int) -> UnsafeRawPointer?).self)),
            let urlCopyString: (@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[7], as: ((@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?).self)),
            let dataGetBytes: (@convention(c) (UnsafeRawPointer?) -> UnsafePointer<UInt8>?) = resolvedFunction(named: symbolNames[8], as: ((@convention(c) (UnsafeRawPointer?) -> UnsafePointer<UInt8>?).self)),
            let dataGetSize: (@convention(c) (UnsafeRawPointer?) -> Int) = resolvedFunction(named: symbolNames[9], as: ((@convention(c) (UnsafeRawPointer?) -> Int).self)),
            let stringGetMaximumUTF8CStringSize: (@convention(c) (UnsafeRawPointer?) -> Int) = resolvedFunction(named: symbolNames[10], as: ((@convention(c) (UnsafeRawPointer?) -> Int).self)),
            let stringGetUTF8CString: (@convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Int) = resolvedFunction(named: symbolNames[11], as: ((@convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Int).self)),
            let errorCopyDomain: (@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[12], as: ((@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?).self)),
            let errorGetErrorCode: (@convention(c) (UnsafeRawPointer?) -> Int32) = resolvedFunction(named: symbolNames[13], as: ((@convention(c) (UnsafeRawPointer?) -> Int32).self)),
            let errorCopyLocalizedDescription: (@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?) = resolvedFunction(named: symbolNames[14], as: ((@convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?).self)),
            let release: (@convention(c) (UnsafeRawPointer?) -> Void) = resolvedFunction(named: symbolNames[15], as: ((@convention(c) (UnsafeRawPointer?) -> Void).self))
        else {
            return nil
        }

        return WISPIWebKitFrameSymbols(
            pageLookUpFrameFromHandle: pageLookUpFrameFromHandle,
            frameCopyURL: frameCopyURL,
            frameCopyMIMEType: frameCopyMIMEType,
            frameIsDisplayingStandaloneImageDocument: frameIsDisplayingStandaloneImageDocument,
            frameGetMainResourceData: frameGetMainResourceData,
            frameGetResourceData: frameGetResourceData,
            urlCreateWithUTF8String: urlCreateWithUTF8String,
            urlCopyString: urlCopyString,
            dataGetBytes: dataGetBytes,
            dataGetSize: dataGetSize,
            stringGetMaximumUTF8CStringSize: stringGetMaximumUTF8CStringSize,
            stringGetUTF8CString: stringGetUTF8CString,
            errorCopyDomain: errorCopyDomain,
            errorGetErrorCode: errorGetErrorCode,
            errorCopyLocalizedDescription: errorCopyLocalizedDescription,
            release: release
        )
    }

    private static func loadedWebKitImage() -> MachOImage? {
        MachOImage.images.first(where: { imagePathMatches($0.path) })
    }

    private static func imagePathMatches(_ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return webKitImagePathSuffixes.contains { path.hasSuffix($0) }
    }

    private static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == textSegmentName })
    }

    private static func resolveLoadedImageSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> UInt64? {
        guard let symbol = image.symbol(named: symbolName, mangled: true, inSection: 0, isGlobalOnly: false),
              symbol.offset >= 0 else {
            return nil
        }

        let offset = UInt64(symbol.offset)
        guard offset < UInt64(text.virtualMemorySize) else {
            return nil
        }

        return UInt64(UInt(bitPattern: image.ptr)) + offset
    }

    private static func resolveSharedCacheSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64,
        cache: DyldCacheLoaded
    ) -> UInt64? {
        guard let localSymbolsInfo = cache.localSymbolsInfo,
              let symbols = localSymbolsInfo.symbols64(in: cache) else {
            return nil
        }

        let dylibOffset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
        guard let entry = localSymbolsInfo.entries(in: cache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
            return nil
        }

        let textVMAddress = UInt64(text.virtualMemoryAddress)
        let textStart = UInt64(UInt(bitPattern: image.ptr))
        let textRange = textStart ..< textStart + UInt64(text.virtualMemorySize)

        for symbolIndex in entry.nlistRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName, symbol.offset >= 0 else {
                continue
            }

            let unslidAddress = UInt64(symbol.offset)
            guard unslidAddress >= textVMAddress else {
                return nil
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress) else {
                return nil
            }
            return resolvedAddress
        }

        return nil
    }
}
#endif

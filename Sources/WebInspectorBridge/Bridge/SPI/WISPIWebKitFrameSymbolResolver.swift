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
    package typealias PageLookUpFrameFromHandleFunction = @convention(c) (WKPageRefRaw?, WKFrameHandleRefRaw?) -> WKFrameRefRaw?
    package typealias FrameCopyURLFunction = @convention(c) (WKFrameRefRaw?) -> WKURLRefRaw?
    package typealias FrameCopyMIMETypeFunction = @convention(c) (WKFrameRefRaw?) -> WKStringRefRaw?
    package typealias FrameIsDisplayingStandaloneImageDocumentFunction = @convention(c) (WKFrameRefRaw?) -> Bool
    package typealias FrameGetMainResourceDataFunction = @convention(c) (WKFrameRefRaw?, FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void
    package typealias FrameGetResourceDataFunction = @convention(c) (WKFrameRefRaw?, WKURLRefRaw?, FrameGetResourceDataCallback, UnsafeMutableRawPointer?) -> Void
    package typealias URLCreateWithUTF8StringFunction = @convention(c) (UnsafePointer<CChar>?, Int) -> WKURLRefRaw?
    package typealias URLCopyStringFunction = @convention(c) (WKURLRefRaw?) -> WKStringRefRaw?
    package typealias DataGetBytesFunction = @convention(c) (WKDataRefRaw?) -> UnsafePointer<UInt8>?
    package typealias DataGetSizeFunction = @convention(c) (WKDataRefRaw?) -> Int
    package typealias StringGetMaximumUTF8CStringSizeFunction = @convention(c) (WKStringRefRaw?) -> Int
    package typealias StringGetUTF8CStringFunction = @convention(c) (WKStringRefRaw?, UnsafeMutablePointer<CChar>?, Int) -> Int
    package typealias ErrorCopyDomainFunction = @convention(c) (WKErrorRefRaw?) -> WKStringRefRaw?
    package typealias ErrorGetErrorCodeFunction = @convention(c) (WKErrorRefRaw?) -> Int32
    package typealias ErrorCopyLocalizedDescriptionFunction = @convention(c) (WKErrorRefRaw?) -> WKStringRefRaw?
    package typealias ReleaseFunction = @convention(c) (WKTypeRefRaw?) -> Void

    package let pageLookUpFrameFromHandle: PageLookUpFrameFromHandleFunction
    package let frameCopyURL: FrameCopyURLFunction
    package let frameCopyMIMEType: FrameCopyMIMETypeFunction
    package let frameIsDisplayingStandaloneImageDocument: FrameIsDisplayingStandaloneImageDocumentFunction
    package let frameGetMainResourceData: FrameGetMainResourceDataFunction
    package let frameGetResourceData: FrameGetResourceDataFunction
    package let urlCreateWithUTF8String: URLCreateWithUTF8StringFunction
    package let urlCopyString: URLCopyStringFunction
    package let dataGetBytes: DataGetBytesFunction
    package let dataGetSize: DataGetSizeFunction
    package let stringGetMaximumUTF8CStringSize: StringGetMaximumUTF8CStringSizeFunction
    package let stringGetUTF8CString: StringGetUTF8CStringFunction
    package let errorCopyDomain: ErrorCopyDomainFunction
    package let errorGetErrorCode: ErrorGetErrorCodeFunction
    package let errorCopyLocalizedDescription: ErrorCopyLocalizedDescriptionFunction
    package let release: ReleaseFunction
}

private enum WISPIWebKitFrameObfuscation {
    static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }
}

private enum WISPIWebKitFrameResolverStrings {
    static let webKitImagePathSuffixes = [
        // /System/Library/Frameworks/WebKit.framework/WebKit
        WISPIWebKitFrameObfuscation.deobfuscate(["it", "ork/WebK", "t.framew", "ks/WebKi", "Framewor", "Library/", "/System/"]),
        // /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
        WISPIWebKitFrameObfuscation.deobfuscate(["ebKit", "ions/A/W", "ork/Vers", "t.framew", "ks/WebKi", "Framewor", "Library/", "/System/"]),
    ]
    // __TEXT
    static let textSegmentName = WISPIWebKitFrameObfuscation.deobfuscate(["__TEXT"])
    static let symbolNames = [
        // _WKPageLookUpFrameFromHandle
        WISPIWebKitFrameObfuscation.deobfuscate(["ndle", "meFromHa", "ookUpFra", "_WKPageL"]),
        // _WKFrameCopyURL
        WISPIWebKitFrameObfuscation.deobfuscate(["CopyURL", "_WKFrame"]),
        // _WKFrameCopyMIMEType
        WISPIWebKitFrameObfuscation.deobfuscate(["Type", "CopyMIME", "_WKFrame"]),
        // _WKFrameIsDisplayingStandaloneImageDocument
        WISPIWebKitFrameObfuscation.deobfuscate(["ent", "ageDocum", "daloneIm", "yingStan", "IsDispla", "_WKFrame"]),
        // _WKFrameGetMainResourceData
        WISPIWebKitFrameObfuscation.deobfuscate(["ata", "esourceD", "GetMainR", "_WKFrame"]),
        // _WKFrameGetResourceData
        WISPIWebKitFrameObfuscation.deobfuscate(["rceData", "GetResou", "_WKFrame"]),
        // _WKURLCreateWithUTF8String
        WISPIWebKitFrameObfuscation.deobfuscate(["ng", "UTF8Stri", "eateWith", "_WKURLCr"]),
        // _WKURLCopyString
        WISPIWebKitFrameObfuscation.deobfuscate(["pyString", "_WKURLCo"]),
        // _WKDataGetBytes
        WISPIWebKitFrameObfuscation.deobfuscate(["etBytes", "_WKDataG"]),
        // _WKDataGetSize
        WISPIWebKitFrameObfuscation.deobfuscate(["etSize", "_WKDataG"]),
        // _WKStringGetMaximumUTF8CStringSize
        WISPIWebKitFrameObfuscation.deobfuscate(["ze", "StringSi", "mumUTF8C", "gGetMaxi", "_WKStrin"]),
        // _WKStringGetUTF8CString
        WISPIWebKitFrameObfuscation.deobfuscate(["CString", "gGetUTF8", "_WKStrin"]),
        // _WKErrorCopyDomain
        WISPIWebKitFrameObfuscation.deobfuscate(["in", "CopyDoma", "_WKError"]),
        // _WKErrorGetErrorCode
        WISPIWebKitFrameObfuscation.deobfuscate(["Code", "GetError", "_WKError"]),
        // _WKErrorCopyLocalizedDescription
        WISPIWebKitFrameObfuscation.deobfuscate(["cription", "lizedDes", "CopyLoca", "_WKError"]),
        // _WKRelease
        WISPIWebKitFrameObfuscation.deobfuscate(["se", "_WKRelea"]),
    ]
}

private func WISPIWebKitImagePath(_ image: MachOImage) -> String? {
    image.path
}

private func WISPIWebKitSegmentName(_ segment: SegmentCommand64) -> String {
    segment.segmentName
}

@unsafe private enum WISPIWebKitFrameSymbolResolverUnsafe {
    static func resolveFunction<T>(address: UInt64?, as _: T.Type) -> T? {
        guard let address else {
            return nil
        }
        return unsafe unsafeBitCast(UnsafeRawPointer(bitPattern: UInt(address)), to: T.self)
    }

    @unsafe static func loadedWebKitImage() -> MachOImage? {
        MachOImage.images.first(where: { unsafe imagePathMatches(WISPIWebKitImagePath($0)) })
    }

    static func imagePathMatches(_ path: String?) -> Bool {
        guard let path else {
            return false
        }
        return WISPIWebKitFrameResolverStrings.webKitImagePathSuffixes.contains { path.hasSuffix($0) }
    }

    @unsafe static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { WISPIWebKitSegmentName($0) == WISPIWebKitFrameResolverStrings.textSegmentName })
    }

    @unsafe static func cacheImage(in cache: DyldCacheLoaded?) -> MachOImage? {
        cache?.machOImages().first(where: { unsafe imagePathMatches(WISPIWebKitImagePath($0)) })
    }

    static func resolveLoadedImageSymbol(
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

        return unsafe UInt64(UInt(bitPattern: image.ptr)) + offset
    }

    static func resolveSharedCacheSymbol(
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
        let textStart = unsafe UInt64(UInt(bitPattern: image.ptr))
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

    static func resolve() -> WISPIWebKitFrameSymbols? {
        guard let loadedImage = unsafe loadedWebKitImage(),
              let loadedTextSegment = unsafe textSegment(in: loadedImage) else {
            return nil
        }

        let cache = DyldCacheLoaded.current
        let cacheImage = unsafe cacheImage(in: cache)
        let cacheTextSegment = cacheImage.flatMap { unsafe textSegment(in: $0) }

        func resolvedFunction<T>(named symbolName: String, as type: T.Type) -> T? {
            if let function = unsafe resolveFunction(
                address: unsafe resolveLoadedImageSymbol(named: symbolName, in: loadedImage, text: loadedTextSegment),
                as: type
            ) {
                return function
            }
            if let cache,
               let cacheImage,
               let cacheTextSegment {
                return unsafe resolveFunction(
                    address: unsafe resolveSharedCacheSymbol(
                        named: symbolName,
                        in: cacheImage,
                        text: cacheTextSegment,
                        cache: cache
                    ),
                    as: type
                )
            }
            return nil
        }

        let symbolNames = WISPIWebKitFrameResolverStrings.symbolNames

        guard
            let pageLookUpFrameFromHandle: WISPIWebKitFrameSymbols.PageLookUpFrameFromHandleFunction = unsafe resolvedFunction(named: symbolNames[0], as: WISPIWebKitFrameSymbols.PageLookUpFrameFromHandleFunction.self),
            let frameCopyURL: WISPIWebKitFrameSymbols.FrameCopyURLFunction = unsafe resolvedFunction(named: symbolNames[1], as: WISPIWebKitFrameSymbols.FrameCopyURLFunction.self),
            let frameCopyMIMEType: WISPIWebKitFrameSymbols.FrameCopyMIMETypeFunction = unsafe resolvedFunction(named: symbolNames[2], as: WISPIWebKitFrameSymbols.FrameCopyMIMETypeFunction.self),
            let frameIsDisplayingStandaloneImageDocument: WISPIWebKitFrameSymbols.FrameIsDisplayingStandaloneImageDocumentFunction = unsafe resolvedFunction(named: symbolNames[3], as: WISPIWebKitFrameSymbols.FrameIsDisplayingStandaloneImageDocumentFunction.self),
            let frameGetMainResourceData: WISPIWebKitFrameSymbols.FrameGetMainResourceDataFunction = unsafe resolvedFunction(named: symbolNames[4], as: WISPIWebKitFrameSymbols.FrameGetMainResourceDataFunction.self),
            let frameGetResourceData: WISPIWebKitFrameSymbols.FrameGetResourceDataFunction = unsafe resolvedFunction(named: symbolNames[5], as: WISPIWebKitFrameSymbols.FrameGetResourceDataFunction.self),
            let urlCreateWithUTF8String: WISPIWebKitFrameSymbols.URLCreateWithUTF8StringFunction = unsafe resolvedFunction(named: symbolNames[6], as: WISPIWebKitFrameSymbols.URLCreateWithUTF8StringFunction.self),
            let urlCopyString: WISPIWebKitFrameSymbols.URLCopyStringFunction = unsafe resolvedFunction(named: symbolNames[7], as: WISPIWebKitFrameSymbols.URLCopyStringFunction.self),
            let dataGetBytes: WISPIWebKitFrameSymbols.DataGetBytesFunction = unsafe resolvedFunction(named: symbolNames[8], as: WISPIWebKitFrameSymbols.DataGetBytesFunction.self),
            let dataGetSize: WISPIWebKitFrameSymbols.DataGetSizeFunction = unsafe resolvedFunction(named: symbolNames[9], as: WISPIWebKitFrameSymbols.DataGetSizeFunction.self),
            let stringGetMaximumUTF8CStringSize: WISPIWebKitFrameSymbols.StringGetMaximumUTF8CStringSizeFunction = unsafe resolvedFunction(named: symbolNames[10], as: WISPIWebKitFrameSymbols.StringGetMaximumUTF8CStringSizeFunction.self),
            let stringGetUTF8CString: WISPIWebKitFrameSymbols.StringGetUTF8CStringFunction = unsafe resolvedFunction(named: symbolNames[11], as: WISPIWebKitFrameSymbols.StringGetUTF8CStringFunction.self),
            let errorCopyDomain: WISPIWebKitFrameSymbols.ErrorCopyDomainFunction = unsafe resolvedFunction(named: symbolNames[12], as: WISPIWebKitFrameSymbols.ErrorCopyDomainFunction.self),
            let errorGetErrorCode: WISPIWebKitFrameSymbols.ErrorGetErrorCodeFunction = unsafe resolvedFunction(named: symbolNames[13], as: WISPIWebKitFrameSymbols.ErrorGetErrorCodeFunction.self),
            let errorCopyLocalizedDescription: WISPIWebKitFrameSymbols.ErrorCopyLocalizedDescriptionFunction = unsafe resolvedFunction(named: symbolNames[14], as: WISPIWebKitFrameSymbols.ErrorCopyLocalizedDescriptionFunction.self),
            let release: WISPIWebKitFrameSymbols.ReleaseFunction = unsafe resolvedFunction(named: symbolNames[15], as: WISPIWebKitFrameSymbols.ReleaseFunction.self)
        else {
            return nil
        }

        return unsafe WISPIWebKitFrameSymbols(
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
}

package enum WISPIWebKitFrameSymbolResolver {
    private static let cachedSymbols = unsafe WISPIWebKitFrameSymbolResolverUnsafe.resolve()

    package static func symbols() -> WISPIWebKitFrameSymbols? {
        unsafe cachedSymbols
    }
}
#endif

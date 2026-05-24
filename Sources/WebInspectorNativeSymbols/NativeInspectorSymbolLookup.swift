#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func resolveLoadedImageSymbol(
        namedAnyOf symbolNames: [String],
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        resolveFirstAvailableSymbol(namedAnyOf: symbolNames) { symbolName in
            resolveLoadedImageSymbol(named: symbolName, in: image, text: text)
        }
    }

    static func resolveSharedCacheSymbol(
        namedAnyOf symbolNames: [String],
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        resolveFirstAvailableSymbol(namedAnyOf: symbolNames) { symbolName in
            resolveSharedCacheSymbol(
                named: symbolName,
                symbols: symbols,
                symbolRange: symbolRange,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            )
        }
    }

    static func resolveSharedCacheSymbol(
        namedAnyOf symbolNames: [String],
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        resolveFirstAvailableSymbol(namedAnyOf: symbolNames) { symbolName in
            resolveSharedCacheSymbol(
                named: symbolName,
                symbols: symbols,
                symbolRange: symbolRange,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            )
        }
    }

    static func resolveFirstAvailableSymbol(
        namedAnyOf symbolNames: [String],
        resolver: (String) -> ResolvedNativeInspectorAddress
    ) -> ResolvedNativeInspectorAddress {
        var outsideTextResult: ResolvedNativeInspectorAddress?
        for symbolName in symbolNames {
            let result = resolver(symbolName)
            switch result {
            case .found:
                return result
            case .outsideText:
                if outsideTextResult == nil {
                    outsideTextResult = result
                }
            case .missing:
                continue
            }
        }
        return outsideTextResult ?? .missing
    }
}
#endif

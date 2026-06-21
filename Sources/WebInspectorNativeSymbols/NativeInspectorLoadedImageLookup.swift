#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func loadedWebKitImage(pathSuffixes: [String]) -> LoadedNativeInspectorImage? {
        guard let image = unsafe MachOKitSymbolLookup.loadedImage(matching: pathSuffixes) else {
            return nil
        }

        return LoadedNativeInspectorImage(
            headerAddress: unsafe UInt(bitPattern: image.ptr)
        )
    }

    static func imagePathMatches(_ path: String?, suffixes: [String]) -> Bool {
        guard let path else {
            return false
        }
        return suffixes.contains { path.hasSuffix($0) }
    }

    static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == "__TEXT" })
    }

    static func textSegment(in image: MachOFile) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == "__TEXT" })
    }

    static func resolveLoadedImageSymbol(
        matching requiredSymbol: NativeInspectorRequiredSymbol,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        let imageBaseAddress = unsafe UInt64(UInt(bitPattern: image.ptr))
        var candidates = Set<UInt64>()
        var outsideTextAddress: UInt64?

        for symbol in image.symbols {
            let variants = unsafe NativeInspectorSymbolName.variants(for: symbol.nameC)
            guard unsafe requiredSymbol.matches(cStringVariants: variants) else {
                continue
            }
            appendLoadedImageSymbolAddress(
                offset: symbol.offset,
                imageBaseAddress: imageBaseAddress,
                text: text,
                candidates: &candidates,
                outsideTextAddress: &outsideTextAddress
            )
            if candidates.count > 1 {
                return .ambiguous
            }
        }

        for symbol in image.exportedSymbols where requiredSymbol.matches(symbolName: symbol.name) {
            guard let offset = symbol.offset else {
                continue
            }
            appendLoadedImageSymbolAddress(
                offset: offset,
                imageBaseAddress: imageBaseAddress,
                text: text,
                candidates: &candidates,
                outsideTextAddress: &outsideTextAddress
            )
            if candidates.count > 1 {
                return .ambiguous
            }
        }

        return resolvedAddress(from: candidates, outsideTextAddress: outsideTextAddress)
    }

    private static func appendLoadedImageSymbolAddress(
        offset: Int,
        imageBaseAddress: UInt64,
        text: SegmentCommand64,
        candidates: inout Set<UInt64>,
        outsideTextAddress: inout UInt64?
    ) {
        guard offset >= 0 else {
            return
        }

        let unsignedOffset = UInt64(offset)
        let address = imageBaseAddress + unsignedOffset
        guard unsignedOffset < UInt64(text.virtualMemorySize) else {
            if outsideTextAddress == nil {
                outsideTextAddress = address
            }
            return
        }
        candidates.insert(address)
    }

    static func resolvedAddress(
        _ address: UInt64,
        belongsToAnyOf expectedHeaderAddresses: [UInt]
    ) -> Bool {
        guard let image = unsafe MachOKitSymbolLookup.image(containingAddress: address) else {
            return false
        }
        return expectedHeaderAddresses.contains(unsafe UInt(bitPattern: image.ptr))
    }
}
#endif

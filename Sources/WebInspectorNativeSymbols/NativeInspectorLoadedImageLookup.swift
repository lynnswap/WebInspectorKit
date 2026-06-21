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
        resolveLoadedImageSymbols(
            matching: [NativeInspectorSymbolMatchTarget(role: requiredSymbol.role, symbol: requiredSymbol)],
            in: image,
            text: text
        )[requiredSymbol.role] ?? .missing
    }

    static func resolveLoadedImageSymbols(
        matching targets: [NativeInspectorSymbolMatchTarget],
        in image: MachOImage,
        text: SegmentCommand64
    ) -> [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress] {
        guard !targets.isEmpty else {
            return [:]
        }

        let imageBaseAddress = unsafe UInt64(UInt(bitPattern: image.ptr))
        var buckets = Array(repeating: NativeInspectorResolvedSymbolBucket(), count: targets.count)

        for symbol in image.symbols where buckets.contains(where: { !$0.isAmbiguous }) {
            let variants = unsafe NativeInspectorSymbolName.variants(for: symbol.nameC)

            for targetIndex in targets.indices {
                guard !buckets[targetIndex].isAmbiguous,
                      unsafe targets[targetIndex].symbol.matches(cStringVariants: variants) else {
                    continue
                }
                appendLoadedImageSymbolAddress(
                    offset: symbol.offset,
                    imageBaseAddress: imageBaseAddress,
                    text: text,
                    bucket: &buckets[targetIndex]
                )
            }
        }

        for symbol in image.exportedSymbols where buckets.contains(where: { !$0.isAmbiguous }) {
            guard let offset = symbol.offset else {
                continue
            }
            let variants = NativeInspectorSymbolName.variants(for: symbol.name)

            for targetIndex in targets.indices {
                guard !buckets[targetIndex].isAmbiguous,
                      targets[targetIndex].symbol.matches(variants: variants) else {
                    continue
                }
                appendLoadedImageSymbolAddress(
                    offset: offset,
                    imageBaseAddress: imageBaseAddress,
                    text: text,
                    bucket: &buckets[targetIndex]
                )
            }
        }

        var resolvedSymbols = [NativeInspectorSymbolRole: ResolvedNativeInspectorAddress]()
        resolvedSymbols.reserveCapacity(targets.count)
        for targetIndex in targets.indices {
            resolvedSymbols[targets[targetIndex].role] = buckets[targetIndex].resolvedAddress
        }
        return resolvedSymbols
    }

    private static func appendLoadedImageSymbolAddress(
        offset: Int,
        imageBaseAddress: UInt64,
        text: SegmentCommand64,
        bucket: inout NativeInspectorResolvedSymbolBucket
    ) {
        guard offset >= 0 else {
            return
        }

        let unsignedOffset = UInt64(offset)
        let address = imageBaseAddress + unsignedOffset
        guard unsignedOffset < UInt64(text.virtualMemorySize) else {
            if bucket.outsideTextAddress == nil {
                bucket.outsideTextAddress = address
            }
            return
        }
        bucket.insertCandidate(address)
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

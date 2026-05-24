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

    static func resolveLoadedImageSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        guard let symbol = image.symbol(named: symbolName, mangled: true, inSection: 0, isGlobalOnly: false) else {
            return unsafe resolveLoadedImageExportedSymbol(
                named: symbolName,
                in: image,
                text: text
            )
        }
        guard symbol.offset >= 0 else {
            return .missing
        }

        let offset = UInt64(symbol.offset)
        let address = unsafe UInt64(UInt(bitPattern: image.ptr)) + offset
        guard offset < UInt64(text.virtualMemorySize) else {
            return .outsideText(address)
        }

        return .found(address)
    }

    @unsafe static func resolveLoadedImageExportedSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        let exportTrie = image.exportTrie
        if let exportedSymbol = exportTrie?.search(by: symbolName),
           let offset = exportedSymbol.offset,
           offset >= 0 {
            let unsignedOffset = UInt64(offset)
            let address = unsafe UInt64(UInt(bitPattern: image.ptr)) + unsignedOffset
            guard unsignedOffset < UInt64(text.virtualMemorySize) else {
                return .outsideText(address)
            }
            return .found(address)
        }

        guard let address = unsafe MachOKitSymbolLookup.exportedRuntimeSymbolAddress(named: symbolName) else {
            return .missing
        }

        let expectedHeaderAddress = unsafe UInt(bitPattern: image.ptr)
        guard resolvedAddress(address, belongsToAnyOf: [expectedHeaderAddress]) else {
            return .missing
        }

        let imageBaseAddress = UInt64(expectedHeaderAddress)
        let textStart = imageBaseAddress
        let textEnd = textStart + UInt64(text.virtualMemorySize)
        guard address >= textStart, address < textEnd else {
            return .outsideText(address)
        }
        return .found(address)
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

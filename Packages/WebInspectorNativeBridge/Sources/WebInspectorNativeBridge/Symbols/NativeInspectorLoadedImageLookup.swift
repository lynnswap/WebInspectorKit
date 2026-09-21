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
        var candidateTargetIndices = [Int]()
        candidateTargetIndices.reserveCapacity(targets.count)

        for symbol in image.symbols where buckets.contains(where: { !$0.isAmbiguous }) {
            candidateTargetIndices.removeAll(keepingCapacity: true)
            for targetIndex in targets.indices where !buckets[targetIndex].isAmbiguous {
                if unsafe targets[targetIndex].symbol.mayMatch(symbolNameC: symbol.nameC) {
                    candidateTargetIndices.append(targetIndex)
                }
            }
            guard !candidateTargetIndices.isEmpty else {
                continue
            }

            let decodedName = unsafe NativeInspectorSymbolName.decode(symbol.nameC)
            for targetIndex in candidateTargetIndices {
                guard targets[targetIndex].symbol.matches(
                    decodedName: decodedName
                ) else {
                    continue
                }
                appendLoadedImageSymbolAddress(
                    offset: symbol.offset,
                    imageBaseAddress: imageBaseAddress,
                    text: text,
                    policy: targets[targetIndex].symbol.resolutionPolicy,
                    bucket: &buckets[targetIndex]
                )
            }
        }

        for symbol in image.exportedSymbols where buckets.contains(where: \.needsCandidateScan) {
            guard let offset = symbol.offset else {
                continue
            }
            var cachedDecodedName: NativeInspectorSymbolName.Decoded?

            for targetIndex in targets.indices {
                guard buckets[targetIndex].needsCandidateScan,
                      targets[targetIndex].symbol.mayMatch(rawSymbolName: symbol.name) else {
                    continue
                }

                let decodedName: NativeInspectorSymbolName.Decoded
                if let cachedDecodedName {
                    decodedName = cachedDecodedName
                } else {
                    let newDecodedName = NativeInspectorSymbolName.decode(symbol.name)
                    cachedDecodedName = newDecodedName
                    decodedName = newDecodedName
                }

                guard targets[targetIndex].symbol.matches(
                    decodedName: decodedName
                ) else {
                    continue
                }
                appendLoadedImageSymbolAddress(
                    offset: offset,
                    imageBaseAddress: imageBaseAddress,
                    text: text,
                    policy: targets[targetIndex].symbol.resolutionPolicy,
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
        policy: NativeInspectorSymbolResolutionPolicy,
        bucket: inout NativeInspectorResolvedSymbolBucket
    ) {
        guard offset > 0 else { return }
        let address = imageBaseAddress + UInt64(offset)
        recordSymbol(address: address,
                     inCode: loadedImageSymbolOffsetIsUsable(offset, textVirtualMemorySize: UInt64(text.virtualMemorySize)),
                     policy: policy, bucket: &bucket)
    }

    static func recordSymbol(address: UInt64, inCode: Bool, policy: NativeInspectorSymbolResolutionPolicy,
                             bucket: inout NativeInspectorResolvedSymbolBucket) {
        let valid: Bool
        switch policy {
        case .requiredTextSymbol:
            valid = inCode
        case .requiredDataSymbol:
            valid = isVTableAddress(address)
        }
        if valid {
            bucket.insertCandidate(address)
        } else if bucket.outsideSectionAddress == nil {
            bucket.outsideSectionAddress = address
        }
    }

    static func isVTableAddress(_ address: UInt64) -> Bool {
        guard let image = unsafe MachOKitSymbolLookup.image(containingAddress: address),
              let text = textSegment(in: image) else { return false }
        let base = unsafe UInt64(UInt(bitPattern: image.ptr))
        guard base >= UInt64(text.virtualMemoryAddress) else { return false }
        let slide = base - UInt64(text.virtualMemoryAddress)
        return image.sections64.contains { section in
            guard section.sectionName == "__const",
                  section.segmentName.hasPrefix("__DATA") || section.segmentName.hasPrefix("__AUTH"),
                  section.address >= 0, section.size >= 3 * MemoryLayout<UInt>.size else { return false }
            let start = UInt64(section.address) + slide
            return address >= start && address - start <= UInt64(section.size - 3 * MemoryLayout<UInt>.size)
        }
    }

    static func loadedImageSymbolOffsetIsUsable(
        _ offset: Int,
        textVirtualMemorySize: UInt64
    ) -> Bool {
        guard offset > 0 else {
            return false
        }
        return UInt64(offset) < textVirtualMemorySize
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

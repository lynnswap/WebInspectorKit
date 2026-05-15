#if os(iOS) || os(macOS)
import Darwin
import MachO
import MachOKit

@unsafe enum MachOKitSymbolLookup {
    static var currentSharedCache: DyldCacheLoaded? {
        DyldCacheLoaded.current
    }

    static var hostSharedCache: DyldCache? {
        DyldCache.host
    }

    static var hostSharedCachePath: String? {
        unsafe hostSharedCache?.url.path
    }

    static func loadedImage(matching pathSuffixes: [String]) -> MachOImage? {
        MachOImage.images.first { image in
            guard let path = image.path else {
                return false
            }
            return pathSuffixes.contains { path.hasSuffix($0) }
        }
    }

    static func image(containingAddress address: UInt64) -> MachOImage? {
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: UInt(address)) else {
            return nil
        }
        return unsafe MachOImage.image(for: pointer)
    }

    static func exportedRuntimeSymbolAddress(named symbolName: String) -> UInt64? {
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbolName) else {
            return nil
        }
        return UInt64(UInt(bitPattern: symbol))
    }
}
#endif

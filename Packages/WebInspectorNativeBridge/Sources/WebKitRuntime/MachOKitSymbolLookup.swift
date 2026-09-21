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

    static var hostFullSharedCache: FullDyldCache? {
        FullDyldCache.host
    }

    static var hostSharedCachePath: String? {
        unsafe hostSharedCache?.url.path
    }

    static func loadedImage(matching pathSuffixes: [String]) -> MachOImage? {
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            guard let header = unsafe _dyld_get_image_header(index) else {
                continue
            }
            let image = unsafe MachOImage(ptr: header)
            let dyldImagePath: String?
            if let dyldImageName = unsafe _dyld_get_image_name(index) {
                dyldImagePath = unsafe String(cString: dyldImageName)
            } else {
                dyldImagePath = nil
            }
            let paths = [image.path, dyldImagePath].compactMap { $0 }
            if paths.contains(where: { path in pathSuffixes.contains { path.hasSuffix($0) } }) {
                return image
            }
        }
        return nil
    }

    static func image(containingAddress address: UInt64) -> MachOImage? {
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: UInt(address)) else {
            return nil
        }
        // dyld already indexes loaded images; avoid scanning every image's segments on cache hits.
        var info = unsafe Dl_info()
        guard unsafe dladdr(pointer, &info) != 0, let base = unsafe info.dli_fbase else { return nil }
        return unsafe MachOImage(ptr: base.assumingMemoryBound(to: mach_header.self))
    }
}
#endif

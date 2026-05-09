#if os(iOS) || os(macOS)
import Darwin
import MachO

@unsafe enum WITransportDyldRuntime {
    typealias SharedCacheRangeFunction = @convention(c) (UnsafeMutablePointer<Int>) -> UnsafeRawPointer?
    typealias ImageHeaderContainingAddressFunction = @convention(c) (UnsafeRawPointer) -> UnsafePointer<mach_header>?
    typealias SharedCacheFilePathFunction = @convention(c) () -> UnsafePointer<CChar>?

    @unsafe struct SharedCacheRange {
        let pointer: UnsafeRawPointer
        let length: UInt
    }

    private static let fallbackLibraryPath = "/usr/lib/system/libdyld.dylib"
    nonisolated(unsafe) private static let fallbackHandle = unsafe dlopen(
        fallbackLibraryPath,
        RTLD_LAZY | RTLD_LOCAL
    )
    nonisolated(unsafe) private static let symbolSearchHandles: [UnsafeMutableRawPointer?] = unsafe [
        unsafe UnsafeMutableRawPointer(bitPattern: -2),
        fallbackHandle,
    ]

    private static let sharedCacheRangeFunction = unsafe resolveSymbol(
        named: deobfuscate(["_range", "_cache", "_shared", "_get", "dyld", "_"]),
        as: SharedCacheRangeFunction.self
    )
    private static let imageHeaderContainingAddressFunction = unsafe resolveSymbol(
        named: deobfuscate(["_address", "_containing", "_header", "_image", "dyld"]),
        as: ImageHeaderContainingAddressFunction.self
    )
    private static let sharedCacheFilePathFunction = unsafe resolveSymbol(
        named: deobfuscate(["_path", "_file", "_cache", "_shared", "dyld"]),
        as: SharedCacheFilePathFunction.self
    )

    static func sharedCacheRange() -> SharedCacheRange? {
        guard let function = unsafe sharedCacheRangeFunction else {
            return nil
        }

        var length = 0
        guard let pointer = unsafe function(&length), length >= 0 else {
            return nil
        }

        return unsafe SharedCacheRange(
            pointer: pointer,
            length: UInt(length)
        )
    }

    static func imageHeader(containing address: UnsafeRawPointer) -> UnsafePointer<mach_header>? {
        guard let function = unsafe imageHeaderContainingAddressFunction else {
            return nil
        }
        return unsafe function(address)
    }

    static func imageHeader(containingAddress address: UInt64) -> UnsafePointer<mach_header>? {
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: UInt(address)) else {
            return nil
        }
        return unsafe imageHeader(containing: pointer)
    }

    static func sharedCacheFilePath() -> String? {
        guard let function = unsafe sharedCacheFilePathFunction,
              let path = unsafe function() else {
            return nil
        }
        return unsafe String(cString: path)
    }

    static func symbolAddress(named symbolName: String) -> UInt64? {
        var iterator = unsafe symbolSearchHandles.makeIterator()
        while let candidate = unsafe iterator.next() {
            guard let handle = unsafe candidate,
                  let symbol = unsafe dlsym(handle, symbolName) else {
                continue
            }
            return UInt64(UInt(bitPattern: symbol))
        }
        return nil
    }

    private static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }

    private static func resolveSymbol<T>(
        named symbolName: String,
        as type: T.Type
    ) -> T? {

        var iterator = unsafe symbolSearchHandles.makeIterator()
        while let candidate = unsafe iterator.next() {
            guard let handle = unsafe candidate,
                  let symbol = unsafe dlsym(handle, symbolName) else {
                continue
            }
            return unsafe unsafeBitCast(symbol, to: T.self)
        }

        return nil
    }
}
#endif

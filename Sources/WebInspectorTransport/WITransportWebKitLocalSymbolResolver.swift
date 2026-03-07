#if os(iOS)
import Foundation
import MachO
import MachOKit

private enum WIKWebKitLocalSymbolFailure: String {
    case sharedCacheUnavailable = "shared cache unavailable"
    case localSymbolsUnavailable = "local symbols unavailable"
    case webKitImageMissing = "WebKit image missing"
    case webKitLocalSymbolEntryMissing = "WebKit local symbol entry missing"
    case connectDisconnectSymbolMissing = "connect/disconnect symbol missing"
    case resolvedAddressOutsideWebKitText = "resolved address outside WebKit text"
}

private struct WIKLoadedWebKitImage {
    let path: String
    let headerAddress: UInt

    var header: UnsafePointer<mach_header> {
        unsafe UnsafePointer<mach_header>(bitPattern: headerAddress)!
    }
}

private struct WIKFileBackedLocalSymbols {
    let cachePath: String
    let symbols: MachOFile.Symbols64
    let symbolRange: Range<Int>
}

private struct WIKLookupFailure: Error {
    let kind: WIKWebKitLocalSymbolFailure
    let detail: String?
}

private enum WIKResolvedAddress {
    case found(UInt64)
    case missing
    case outsideText(UInt64)
}

private struct WIKWebKitLocalSymbolResolution: Sendable {
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let failureReason: String?

    init(connectFrontendAddress: UInt64, disconnectFrontendAddress: UInt64, failureReason: String?) {
        self.connectFrontendAddress = connectFrontendAddress
        self.disconnectFrontendAddress = disconnectFrontendAddress
        self.failureReason = failureReason
    }
}

private enum WIKWebKitLocalSymbolResolver {
    private static let webKitImagePath = "/System/Library/Frameworks/WebKit.framework/WebKit"
    private static let textSegmentName = "__TEXT"
    private static let sharedCacheFilePrefix = "dyld_shared_cache_"
    private static let deviceSharedCacheDirectoryCandidates = [
        "/System/Library/Caches/com.apple.dyld",
        "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
        "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
    ]
    private static let connectFrontendSymbol = "__ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb"
    private static let disconnectFrontendSymbol = "__ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE"

    private static let cachedResolution = resolve(
        imagePathSuffix: webKitImagePath,
        connectSymbol: connectFrontendSymbol,
        disconnectSymbol: disconnectFrontendSymbol
    )

    static func resolveCurrentWebKitAttachSymbols() -> WIKWebKitLocalSymbolResolution {
        cachedResolution
    }

    static func resolveForTesting(
        imagePathSuffix: String = webKitImagePath,
        connectSymbol: String = connectFrontendSymbol,
        disconnectSymbol: String = disconnectFrontendSymbol
    ) -> WIKWebKitLocalSymbolResolution {
        resolve(
            imagePathSuffix: imagePathSuffix,
            connectSymbol: connectSymbol,
            disconnectSymbol: disconnectSymbol
        )
    }

    private static func resolve(
        imagePathSuffix: String,
        connectSymbol: String,
        disconnectSymbol: String
    ) -> WIKWebKitLocalSymbolResolution {
        #if targetEnvironment(simulator)
        return resolveInSimulator(
            imagePathSuffix: imagePathSuffix,
            connectSymbol: connectSymbol,
            disconnectSymbol: disconnectSymbol
        )
        #else
        return resolveOnDevice(
            imagePathSuffix: imagePathSuffix,
            connectSymbol: connectSymbol,
            disconnectSymbol: disconnectSymbol
        )
        #endif
    }

    private static func resolveInSimulator(
        imagePathSuffix: String,
        connectSymbol: String,
        disconnectSymbol: String
    ) -> WIKWebKitLocalSymbolResolution {
        guard let loadedImage = loadedWebKitImage(pathSuffix: imagePathSuffix) else {
            return failure(.webKitImageMissing)
        }

        let image = unsafe MachOImage(ptr: loadedImage.header)
        guard image.is64Bit, let text = textSegment(in: image) else {
            return failure(.webKitImageMissing, detail: "Missing a 64-bit __TEXT segment.")
        }

        let connectResult = resolveSimulatorSymbol(named: connectSymbol, in: image, text: text)
        let disconnectResult = resolveSimulatorSymbol(named: disconnectSymbol, in: image, text: text)
        return finalizeResolution(
            connectResult: connectResult,
            disconnectResult: disconnectResult,
            successLog: "resolved symbol via MachOKit simulator symbol table",
            imagePath: loadedImage.path
        )
    }

    private static func resolveOnDevice(
        imagePathSuffix: String,
        connectSymbol: String,
        disconnectSymbol: String
    ) -> WIKWebKitLocalSymbolResolution {
        guard let loadedImage = loadedWebKitImage(pathSuffix: imagePathSuffix) else {
            return failure(.webKitImageMissing)
        }

        var sharedCacheSize: UInt = 0
        guard let sharedCachePointer = unsafe _dyld_get_shared_cache_range(&sharedCacheSize) else {
            return failure(.sharedCacheUnavailable)
        }

        let cache: DyldCacheLoaded
        do {
            cache = try unsafe DyldCacheLoaded(ptr: sharedCachePointer)
        } catch {
            return failure(.sharedCacheUnavailable, detail: error.localizedDescription)
        }

        guard let webKitImage = cache.machOImages().first(where: { ($0.path ?? "").hasSuffix(imagePathSuffix) }) else {
            return failure(.webKitImageMissing)
        }
        guard webKitImage.is64Bit, let text = textSegment(in: webKitImage) else {
            return failure(.webKitImageMissing, detail: "Missing a 64-bit __TEXT segment.")
        }

        guard let slide = cache.slide, slide >= 0 else {
            return failure(.sharedCacheUnavailable, detail: "The dyld cache slide was unavailable.")
        }

        let textStart = unsafe UInt64(UInt(bitPattern: loadedImage.header))
        let textRange = textStart ..< textStart + UInt64(text.virtualMemorySize)

        if let localSymbolsInfo = cache.localSymbolsInfo {
            let dylibOffset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
            guard let entry = localSymbolsInfo.entries(in: cache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
                return failure(.webKitLocalSymbolEntryMissing)
            }
            guard let symbols = localSymbolsInfo.symbols64(in: cache) else {
                return failure(.localSymbolsUnavailable, detail: "The loaded dyld cache could not materialize 64-bit local symbols.")
            }

            let lowerBound = entry.nlistStartIndex
            let upperBound = lowerBound + entry.nlistCount
            guard lowerBound >= 0, upperBound >= lowerBound, upperBound <= symbols.count else {
                return failure(.localSymbolsUnavailable, detail: "The WebKit local symbol entry range was invalid.")
            }

            let connectResult = resolveDeviceSymbol(
                named: connectSymbol,
                symbols: symbols,
                symbolRange: lowerBound ..< upperBound,
                textVMAddress: UInt64(text.virtualMemoryAddress),
                textRange: textRange,
                slide: UInt64(slide)
            )
            let disconnectResult = resolveDeviceSymbol(
                named: disconnectSymbol,
                symbols: symbols,
                symbolRange: lowerBound ..< upperBound,
                textVMAddress: UInt64(text.virtualMemoryAddress),
                textRange: textRange,
                slide: UInt64(slide)
            )
            return finalizeResolution(
                connectResult: connectResult,
                disconnectResult: disconnectResult,
                successLog: "resolved symbol via dyld local symbols",
                imagePath: loadedImage.path
            )
        }

        do {
            let dylibOffset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
            let fileBackedSymbols = try fileBackedLocalSymbols(
                mainCacheHeader: cache.mainCacheHeader,
                dylibOffset: dylibOffset
            )
            let connectResult = resolveDeviceSymbol(
                named: connectSymbol,
                symbols: fileBackedSymbols.symbols,
                symbolRange: fileBackedSymbols.symbolRange,
                textVMAddress: UInt64(text.virtualMemoryAddress),
                textRange: textRange,
                slide: UInt64(slide)
            )
            let disconnectResult = resolveDeviceSymbol(
                named: disconnectSymbol,
                symbols: fileBackedSymbols.symbols,
                symbolRange: fileBackedSymbols.symbolRange,
                textVMAddress: UInt64(text.virtualMemoryAddress),
                textRange: textRange,
                slide: UInt64(slide)
            )
            return finalizeResolution(
                connectResult: connectResult,
                disconnectResult: disconnectResult,
                successLog: "resolved symbol via dyld local symbols (file-backed)",
                imagePath: "\(loadedImage.path) cache=\(fileBackedSymbols.cachePath)"
            )
        } catch let lookupFailure as WIKLookupFailure {
            return failure(lookupFailure.kind, detail: lookupFailure.detail)
        } catch {
            return failure(.localSymbolsUnavailable, detail: error.localizedDescription)
        }
    }

    private static func finalizeResolution(
        connectResult: WIKResolvedAddress,
        disconnectResult: WIKResolvedAddress,
        successLog: String,
        imagePath: String
    ) -> WIKWebKitLocalSymbolResolution {
        switch (connectResult, disconnectResult) {
        case let (.found(connectAddress), .found(disconnectAddress)):
            NSLog(
                "[NativeInspectorProbe] %@ image=%@ connect=0x%llx disconnect=0x%llx",
                successLog,
                imagePath,
                connectAddress,
                disconnectAddress
            )
            return WIKWebKitLocalSymbolResolution(
                connectFrontendAddress: connectAddress,
                disconnectFrontendAddress: disconnectAddress,
                failureReason: nil
            )
        case let (.outsideText(address), _), let (_, .outsideText(address)):
            return failure(
                .resolvedAddressOutsideWebKitText,
                detail: unsafe String(format: "Resolved address 0x%llx.", address)
            )
        case (.missing, _), (_, .missing):
            return failure(.connectDisconnectSymbolMissing)
        }
    }

    private static func loadedWebKitImage(pathSuffix: String) -> WIKLoadedWebKitImage? {
        let imageCount = _dyld_image_count()
        for imageIndex in 0 ..< imageCount {
            guard let imageName = unsafe _dyld_get_image_name(imageIndex) else {
                continue
            }

            let path = unsafe String(cString: imageName)
            guard path.hasSuffix(pathSuffix), let header = unsafe _dyld_get_image_header(imageIndex) else {
                continue
            }

            return WIKLoadedWebKitImage(
                path: path,
                headerAddress: UInt(bitPattern: header)
            )
        }

        return nil
    }

    private static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == textSegmentName })
    }

    private static func sharedCacheSymbolFileURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls = [URL]()
        for directoryPath in deviceSharedCacheDirectoryCandidates {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directoryPath) else {
                continue
            }

            let sortedEntries = entries
                .filter { entry in
                    entry.hasPrefix(sharedCacheFilePrefix) && entry.hasSuffix(".symbols")
                }
                .sorted { lhs, rhs in
                    sharedCacheSortKey(for: lhs) < sharedCacheSortKey(for: rhs)
                }

            urls.append(contentsOf: sortedEntries.map {
                URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent($0)
            })
        }
        return urls
    }

    private static func sharedCacheSortKey(for fileName: String) -> Int {
        if fileName.contains("arm64e") {
            return 0
        }
        if fileName.contains("arm64") {
            return 1
        }
        return 2
    }

    private static func fileBackedLocalSymbols(
        mainCacheHeader: DyldCacheHeader,
        dylibOffset: UInt64
    ) throws -> WIKFileBackedLocalSymbols {
        let symbolCacheURLs = sharedCacheSymbolFileURLs()
        guard !symbolCacheURLs.isEmpty else {
            throw WIKLookupFailure(
                kind: .localSymbolsUnavailable,
                detail: "No readable dyld_shared_cache_*.symbols file was found in \(deviceSharedCacheDirectoryCandidates.joined(separator: ", "))."
            )
        }

        var lastFailure: WIKLookupFailure?

        for symbolCacheURL in symbolCacheURLs {
            do {
                let symbolCache = try DyldCache(
                    subcacheUrl: symbolCacheURL,
                    mainCacheHeader: mainCacheHeader
                )
                guard let localSymbolsInfo = symbolCache.localSymbolsInfo else {
                    lastFailure = WIKLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: "MachOKit could not read local symbols info from \(symbolCacheURL.path)."
                    )
                    continue
                }
                guard let entry = localSymbolsInfo.entries(in: symbolCache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
                    lastFailure = WIKLookupFailure(
                        kind: .webKitLocalSymbolEntryMissing,
                        detail: "MachOKit could not find the WebKit dylibOffset 0x\(String(dylibOffset, radix: 16)) in \(symbolCacheURL.path)."
                    )
                    continue
                }
                guard let symbols = localSymbolsInfo.symbols64(in: symbolCache) else {
                    lastFailure = WIKLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: "MachOKit could not materialize 64-bit local symbols from \(symbolCacheURL.path)."
                    )
                    continue
                }

                return WIKFileBackedLocalSymbols(
                    cachePath: symbolCacheURL.path,
                    symbols: symbols,
                    symbolRange: entry.nlistRange
                )
            } catch {
                lastFailure = WIKLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: "\(symbolCacheURL.path): \(error.localizedDescription)"
                )
            }
        }

        throw lastFailure ?? WIKLookupFailure(
            kind: .localSymbolsUnavailable,
            detail: "No dyld shared cache .symbols candidate yielded WebKit local symbols."
        )
    }

    private static func resolveSimulatorSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> WIKResolvedAddress {
        guard let symbol = image.symbol(named: symbolName, mangled: true, inSection: 0, isGlobalOnly: false) else {
            return .missing
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

    private static func resolveDeviceSymbol(
        named symbolName: String,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> WIKResolvedAddress {
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName else {
                continue
            }
            guard symbol.offset >= 0 else {
                return .missing
            }

            let unslidAddress = UInt64(symbol.offset)
            let actualAddress = slide + unslidAddress
            guard unslidAddress >= textVMAddress else {
                return .outsideText(actualAddress)
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
                return .outsideText(actualAddress)
            }
            return .found(actualAddress)
        }

        return .missing
    }

    private static func resolveDeviceSymbol(
        named symbolName: String,
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> WIKResolvedAddress {
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName else {
                continue
            }
            guard symbol.offset >= 0 else {
                return .missing
            }

            let unslidAddress = UInt64(symbol.offset)
            let actualAddress = slide + unslidAddress
            guard unslidAddress >= textVMAddress else {
                return .outsideText(actualAddress)
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
                return .outsideText(actualAddress)
            }
            return .found(actualAddress)
        }

        return .missing
    }

    private static func failure(
        _ kind: WIKWebKitLocalSymbolFailure,
        detail: String? = nil
    ) -> WIKWebKitLocalSymbolResolution {
        let reason: String
        if let detail, !detail.isEmpty {
            reason = "\(kind.rawValue): \(detail)"
        } else {
            reason = kind.rawValue
        }
        NSLog("[NativeInspectorProbe] local symbol resolution failed reason=%@", reason)
        return WIKWebKitLocalSymbolResolution(
            connectFrontendAddress: 0,
            disconnectFrontendAddress: 0,
            failureReason: reason
        )
    }
}

struct WITransportAttachSymbolResolution: Sendable {
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let failureReason: String?

    var supportSnapshot: WITransportSupportSnapshot {
        WITransportSupportSnapshot(
            availability: isSupported ? .supported : .unsupported,
            failureReason: failureReason
        )
    }

    var isSupported: Bool {
        connectFrontendAddress != 0 && disconnectFrontendAddress != 0 && failureReason == nil
    }
}

enum WITransportWebKitLocalSymbolResolver {
    static func currentAttachResolution() -> WITransportAttachSymbolResolution {
        makeAttachResolution(from: WIKWebKitLocalSymbolResolver.resolveCurrentWebKitAttachSymbols())
    }

    static func resolveForTesting(
        imagePathSuffix: String = "/System/Library/Frameworks/WebKit.framework/WebKit",
        connectSymbol: String = "__ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb",
        disconnectSymbol: String = "__ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE"
    ) -> WITransportAttachSymbolResolution {
        makeAttachResolution(
            from: WIKWebKitLocalSymbolResolver.resolveForTesting(
                imagePathSuffix: imagePathSuffix,
                connectSymbol: connectSymbol,
                disconnectSymbol: disconnectSymbol
            )
        )
    }

    private static func makeAttachResolution(from resolution: WIKWebKitLocalSymbolResolution) -> WITransportAttachSymbolResolution {
        WITransportAttachSymbolResolution(
            connectFrontendAddress: resolution.connectFrontendAddress,
            disconnectFrontendAddress: resolution.disconnectFrontendAddress,
            failureReason: resolution.failureReason
        )
    }
}
#endif

#if !os(iOS)
struct WITransportAttachSymbolResolution: Sendable {
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let failureReason: String?

    var supportSnapshot: WITransportSupportSnapshot {
        WITransportSupportSnapshot(
            availability: .unsupported,
            failureReason: failureReason
        )
    }

    var isSupported: Bool { false }
}

enum WITransportWebKitLocalSymbolResolver {
    static func currentAttachResolution() -> WITransportAttachSymbolResolution {
        WITransportAttachSymbolResolution(
            connectFrontendAddress: 0,
            disconnectFrontendAddress: 0,
            failureReason: "WebInspectorTransport is only available on iOS."
        )
    }

    static func resolveForTesting(
        imagePathSuffix: String = "",
        connectSymbol: String = "",
        disconnectSymbol: String = ""
    ) -> WITransportAttachSymbolResolution {
        currentAttachResolution()
    }
}
#endif

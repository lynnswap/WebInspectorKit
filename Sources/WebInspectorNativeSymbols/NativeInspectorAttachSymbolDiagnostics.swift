#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

#if DEBUG
private enum NativeInspectorSymbolDiagnostics {
    private static let similarAttachSymbolLogState = NativeInspectorSimilarAttachSymbolLogState()

    static func reserveSimilarAttachSymbolLog() -> Bool {
        similarAttachSymbolLogState.reserve()
    }
}

private final class NativeInspectorSimilarAttachSymbolLogState: @unchecked Sendable {
    private let lock = NSLock()
    private var didLog = false

    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didLog else {
            return false
        }
        didLog = true
        return true
    }
}

enum NativeInspectorAttachSymbolRole: String {
    case connect
    case disconnect
    case unknown
}

struct NativeInspectorAttachSymbolCandidate {
    let role: NativeInspectorAttachSymbolRole
    let source: String
    let imageName: String
    let ownerKey: String
    let name: String
    let address: UInt64
    let score: Int
}

struct NativeInspectorAttachSymbolScan {
    var scannedCount: Int = 0
    var matchedCount: Int = 0
    var candidates: [NativeInspectorAttachSymbolCandidate] = []
}
#endif

extension NativeInspectorSymbolResolverCore {
    #if DEBUG
    @unsafe static func debugLogSimilarAttachSymbolsIfNeeded(
        for result: NativeInspectorSymbolLookupResult,
        loadedWebKitImage: MachOImage,
        loadedWebKitText: SegmentCommand64,
        loadedWebKitHeaderAddress: UInt,
        loadedWebCoreImage: MachOImage?,
        loadedWebCoreText: SegmentCommand64?,
        loadedWebCoreHeaderAddress: UInt?,
        imagePathSuffixes: [String]
    ) {
        let missingAttachFunctions = result.missingFunctions.filter {
            $0 == "connectFrontend" || $0 == "disconnectFrontend"
        }
        guard !missingAttachFunctions.isEmpty,
              NativeInspectorSymbolDiagnostics.reserveSimilarAttachSymbolLog() else {
            return
        }

        var scans = [
            unsafe debugSimilarLoadedImageAttachSymbols(
                source: "loaded-image",
                imageName: "WebKit",
                image: loadedWebKitImage,
                text: loadedWebKitText
            ),
            unsafe debugSimilarLoadedImageExportAttachSymbols(
                source: "loaded-image-export",
                imageName: "WebKit",
                image: loadedWebKitImage,
                text: loadedWebKitText
            ),
        ]

        if let loadedWebCoreImage, let loadedWebCoreText {
            scans.append(
                unsafe debugSimilarLoadedImageAttachSymbols(
                    source: "loaded-image",
                    imageName: "WebCore",
                    image: loadedWebCoreImage,
                    text: loadedWebCoreText
                )
            )
            scans.append(
                unsafe debugSimilarLoadedImageExportAttachSymbols(
                    source: "loaded-image-export",
                    imageName: "WebCore",
                    image: loadedWebCoreImage,
                    text: loadedWebCoreText
                )
            )
        }

        scans.append(contentsOf: unsafe debugSimilarSharedCacheAttachSymbols(
            loadedWebKitHeaderAddress: loadedWebKitHeaderAddress,
            loadedWebCoreHeaderAddress: loadedWebCoreHeaderAddress,
            imagePathSuffixes: imagePathSuffixes
        ))

        let candidates = scans.flatMap(\.candidates)
        let scannedCount = scans.reduce(0) { $0 + $1.scannedCount }
        let matchedCount = scans.reduce(0) { $0 + $1.matchedCount }
        let scanSummary = scans
            .enumerated()
            .filter { _, scan in scan.scannedCount > 0 || !scan.candidates.isEmpty }
            .map { index, scan in
                "scan\(index)=scanned:\(scan.scannedCount),matched:\(scan.matchedCount),kept:\(scan.candidates.count)"
            }
            .joined(separator: ";")

        NSLog(
            "[WebInspectorNativeSymbols] similar attach symbol scan missing=%@ scanned=%d matched=%d kept=%d %@",
            missingAttachFunctions.joined(separator: ","),
            scannedCount,
            matchedCount,
            candidates.count,
            scanSummary
        )

        debugLogSimilarAttachSymbolPairs(candidates)
        debugLogSimilarAttachSymbolSingles(candidates)
    }
    #endif
}
#endif

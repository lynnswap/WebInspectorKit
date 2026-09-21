import Foundation
import WebKitRuntime

enum NativeInspectorSymbolResolver {
    private static let currentSymbols = NativeInspectorSymbols.current()
    static func resolveCurrent() -> NativeInspectorSymbolResolution {
        makeResolution(symbols: currentSymbols,
                       webKit: .webKit, javaScriptCore: .javaScriptCore, useCache: true)
    }
    static func resolveCurrentDetached() async -> NativeInspectorSymbolResolution {
        await Task.detached(priority: .userInitiated) { resolveCurrent() }.value
    }
    static func resolveForTesting(
        imagePathSuffixes: [String] = RuntimeImage.webKit.pathSuffixes,
        javaScriptCorePathSuffixes: [String] = RuntimeImage.javaScriptCore.pathSuffixes,
        allowSharedCacheFallback: Bool = true,
        symbols: NativeInspectorSymbols = NativeInspectorSymbols.current()
    ) -> NativeInspectorSymbolResolution {
        makeResolution(symbols: symbols, webKit: RuntimeImage(pathSuffixes: imagePathSuffixes),
                       javaScriptCore: RuntimeImage(pathSuffixes: javaScriptCorePathSuffixes),
                       useCache: false, allowSharedCache: allowSharedCacheFallback)
    }
    private static func makeResolution(symbols: NativeInspectorSymbols, webKit: RuntimeImage, javaScriptCore: RuntimeImage,
                                       useCache: Bool, allowSharedCache: Bool = true) -> NativeInspectorSymbolResolution {
        let required = symbols.all
        let queries = required.map { $0.requirement(webKit: webKit, javaScriptCore: javaScriptCore) }
        let results = useCache ? WebKitRuntime.resolveSynchronously(queries)
            : WebKitRuntime.resolveUncached(queries, allowSharedCache: allowSharedCache)
        var missing: [String] = []
        var addresses: [UInt64] = []
        var source = "loaded-image"
        for (requirement, result) in zip(required, results) {
            switch result {
            case .success(let symbol):
                addresses.append(symbol.address)
                if symbol.source != "loaded-image" { source = symbol.source }
            case .failure:
                missing.append(requirement.role.rawValue)
                addresses.append(0)
            }
        }
        return NativeInspectorSymbolResolution(
            addresses: missing.isEmpty ? NativeInspectorSymbolAddresses(
                connectFrontendAddress: addresses[0], disconnectFrontendAddress: addresses[1],
                stringFromUTF8Address: addresses[2], stringImplToNSStringAddress: addresses[3],
                derefStringImplAddress: addresses[4], dispatchMessageFromRemoteAddress: addresses[5], debuggableVTableAddress: addresses[6]
            ) : .zero,
            failureReason: missing.isEmpty ? nil : "Runtime requirements unavailable: phase=\(source) missing=\(missing.joined(separator: ","))",
            failureKind: missing.isEmpty ? nil : "runtime helper unavailable",
            phase: source, missingFunctions: missing, source: source
        )
    }
}

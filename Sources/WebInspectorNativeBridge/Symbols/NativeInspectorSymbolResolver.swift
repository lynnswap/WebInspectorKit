import Foundation
import WebKitRuntime

enum NativeInspectorSymbolResolver {
    private static let currentSymbols = NativeInspectorSymbols.current()
    static func resolveCurrent() throws -> NativeInspectorResolvedSymbols {
        try makeResolution(symbols: currentSymbols,
                       webKit: .webKit, javaScriptCore: .javaScriptCore, useCache: true)
    }
    static func resolveForTesting(
        imagePathSuffixes: [String] = RuntimeImage.webKit.pathSuffixes,
        javaScriptCorePathSuffixes: [String] = RuntimeImage.javaScriptCore.pathSuffixes,
        allowSharedCacheFallback: Bool = true,
        symbols: NativeInspectorSymbols = NativeInspectorSymbols.current()
    ) throws -> NativeInspectorResolvedSymbols {
        try makeResolution(symbols: symbols, webKit: RuntimeImage(pathSuffixes: imagePathSuffixes),
                       javaScriptCore: RuntimeImage(pathSuffixes: javaScriptCorePathSuffixes),
                       useCache: false, allowSharedCache: allowSharedCacheFallback)
    }
    private static func makeResolution(symbols: NativeInspectorSymbols, webKit: RuntimeImage, javaScriptCore: RuntimeImage,
                                       useCache: Bool, allowSharedCache: Bool = true) throws -> NativeInspectorResolvedSymbols {
        let required = symbols.all
        let queries = required.map { $0.requirement(webKit: webKit, javaScriptCore: javaScriptCore) }
        let results = useCache ? WebKitRuntime.resolveSynchronously(queries)
            : WebKitRuntime.resolveUncached(queries, allowSharedCache: allowSharedCache)
        let failures = zip(required, results).compactMap { requirement, result -> NativeInspectorSymbolResolutionError.Failure? in
            guard case .failure(let error) = result else { return nil }
            return .init(role: requirement.role, underlyingError: error)
        }
        if !failures.isEmpty {
            throw NativeInspectorSymbolResolutionError(failures: failures)
        }
        let resolved = try results.map { try $0.get() }
        return NativeInspectorResolvedSymbols(
            connectFrontend: resolved[0], disconnectFrontend: resolved[1],
            stringFromUTF8: resolved[2], stringImplToNSString: resolved[3],
            derefStringImpl: resolved[4], dispatchMessageFromRemote: resolved[5], debuggableVTable: resolved[6]
        )
    }
}

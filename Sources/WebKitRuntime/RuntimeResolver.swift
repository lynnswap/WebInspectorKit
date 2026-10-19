import ABIBridge
import ABIBridgeCore
import Foundation

/// Adapts WebKit requirements to one ABIBridge batch, retaining successful results.
actor RuntimeResolver {
    static let shared = RuntimeResolver()

    private let runtime = ABIRuntime()
    private var cache: [RuntimeSymbol: ResolvedRuntimeSymbol] = [:]

    func resolve(_ symbols: [RuntimeSymbol]) async -> [Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        var paths: [String]?
        var requests: [NativeSymbolRequest] = []
        var indices: [Int] = []
        var results = [Result<ResolvedRuntimeSymbol, RuntimeLookupError>](
            repeating: .failure(.init(.imageUnavailable)), count: symbols.count
        )
        for (index, symbol) in symbols.enumerated() {
            if let cached = cache[symbol] {
                results[index] = .success(cached)
                continue
            }
            do {
                let declarations = symbol.names.compactMap { Self.declaration($0, kind: symbol.kind) }
                guard let primary = declarations.first else {
                    throw RuntimeLookupError(.symbolMissing)
                }
                requests.append(NativeSymbolRequest(
                    primary,
                    alternatives: Array(declarations.dropFirst()),
                    fallbacks: symbol.fallbacks.compactMap { Self.declaration($0, kind: symbol.kind) },
                    in: try Self.imageScopes(for: symbol.images, paths: &paths),
                    loading: .loadedOnly
                ))
                indices.append(index)
            } catch {
                results[index] = .failure(Self.lookupError(error))
            }
        }
        guard !requests.isEmpty else { return results }
        let resolved = await runtime.resolve(requests)
        for (index, result) in zip(indices, resolved) {
            let symbol = symbols[index]
            do {
                let native = try result.get()
                guard let owner = symbol.images.first(where: { owner in
                    owner.pathSuffixes.contains { native.image.path.hasSuffix($0) }
                }) else {
                    throw RuntimeLookupError(.imageUnavailable)
                }
                let value = ResolvedRuntimeSymbol(native, image: owner)
                cache[symbol] = value
                results[index] = .success(value)
            } catch {
                results[index] = .failure(Self.lookupError(error))
            }
        }
        return results
    }

    private static func loadedImagePaths() throws -> [String] {
        // A catalog snapshot owns descriptions only. Unrelated images must not
        // acquire loader leases just to decide which image this request needs.
        guard let list = unsafe ABICopyLoadedImages() else { throw RuntimeLookupError(.imageUnavailable) }
        defer { unsafe ABIFreeImageList(list) }
        return unsafe (0..<ABIImageListCount(list)).map { index in
            let info = unsafe ABIImageListGet(list, index)
            return unsafe String(cString: info.path)
        }
    }

    private static func imageScopes(
        for images: [RuntimeImage], paths: inout [String]?
    ) throws -> [ImageSelector] {
        var scopes: [ImageSelector] = []
        for image in images {
            if image == .webKit {
                scopes.append(.framework(named: "WebKit"))
            } else if image == .javaScriptCore {
                scopes.append(.framework(named: "JavaScriptCore"))
            } else {
                let loaded = try paths ?? loadedImagePaths()
                paths = loaded
                if let path = loaded.first(where: { path in
                    image.pathSuffixes.contains { path.hasSuffix($0) }
                }) {
                    scopes.append(.path(URL(fileURLWithPath: path)))
                }
            }
        }
        return scopes
    }

    private static func declaration(
        _ name: RuntimeSymbol.Name, kind: RuntimeSymbol.Kind
    ) -> NativeDeclaration? {
        let nativeKind: NativeSymbolKind
        switch kind {
        case .function: nativeKind = .function
        case .data: nativeKind = .data
        case .vtable: nativeKind = .vtable
        }
        switch name {
        case .cxx(let name):
            return .init(name: name, language: .cxx, kind: nativeKind)
        case .mangled(let name):
            if name.hasPrefix("__Z") {
                return .init(machOName: name, language: .cxx, kind: nativeKind)
            } else if name.hasPrefix("_Z") {
                return .init(linkerName: name, language: .cxx, kind: nativeKind)
            } else if name.hasPrefix("_") {
                return .init(machOName: name, language: .c, kind: nativeKind)
            }
            return nil
        }
    }

    private static func lookupError(_ error: any Error) -> RuntimeLookupError {
        if let error = error as? RuntimeLookupError { return error }
        // Do not expose ABIBridge's decoded declarations or image paths in
        // WebKitRuntime's deliberately redacted diagnostics.
        switch error {
        case ABIResolutionError.declarationNotFound, ABIResolutionError.metadataUnavailable:
            return .init(.symbolMissing)
        case ABIResolutionError.ambiguousDeclaration:
            return .init(.ambiguousSymbol)
        case ABIResolutionError.invalidAddress, ABIResolutionError.unsupportedDeclaration,
             ABIResolutionError.signatureMismatch:
            return .init(.invalidAddress)
        default:
            return .init(.imageUnavailable)
        }
    }
}

import ABIBridge
import Foundation

/// Adapts WebKit's ordered image/name alternatives to ABIBridge's resolver.
actor RuntimeResolver {
    static let shared = RuntimeResolver()

    private let runtime = ABIRuntime()
    private var cache: [RuntimeSymbol: ResolvedRuntimeSymbol] = [:]

    func resolve(_ symbols: [RuntimeSymbol]) async -> [Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        var images: [NativeImage]?
        var results: [Result<ResolvedRuntimeSymbol, RuntimeLookupError>] = []
        for symbol in symbols {
            if let cached = cache[symbol] {
                results.append(.success(cached))
                continue
            }
            do {
                if images == nil { images = try await runtime.images() }
                let resolved = try await resolve(symbol, images: images!)
                cache[symbol] = resolved
                results.append(.success(resolved))
            } catch {
                results.append(.failure(Self.lookupError(error)))
            }
        }
        return results
    }

    private func resolve(_ symbol: RuntimeSymbol, images: [NativeImage]) async throws -> ResolvedRuntimeSymbol {
        var failure = RuntimeLookupError(.imageUnavailable)
        for owner in symbol.images {
            guard let image = images.first(where: { image in
                owner.pathSuffixes.contains { image.path.hasSuffix($0) }
            }) else {
                failure = RuntimeLookupError(.imageUnavailable)
                continue
            }
            do {
                return try await resolve(symbol, in: image, owner: owner)
            } catch {
                let error = Self.lookupError(error)
                guard error.reason == .symbolMissing || error.reason == .imageUnavailable else { throw error }
                failure = error
            }
        }
        throw failure
    }

    private func resolve(
        _ symbol: RuntimeSymbol, in image: NativeImage, owner: RuntimeImage
    ) async throws -> ResolvedRuntimeSymbol {
        var match: ResolvedRuntimeSymbol?
        var invalidAddress = false
        let kind: NativeSymbolKind
        switch symbol.kind {
        case .function: kind = .function
        case .data: kind = .data
        case .vtable: kind = .vtable
        }
        for name in symbol.names {
            let declaration: NativeDeclaration
            switch name {
            case .cxx(let name):
                declaration = .init(name: name, language: .cxx, kind: kind)
            case .mangled(let name):
                if name.hasPrefix("__Z") {
                    declaration = .init(machOName: name, language: .cxx, kind: kind)
                } else if name.hasPrefix("_Z") {
                    declaration = .init(linkerName: name, language: .cxx, kind: kind)
                } else if name.hasPrefix("_") {
                    declaration = .init(machOName: name, language: .c, kind: kind)
                } else { continue }
            }
            do {
                let resolved = try await runtime.resolve(declaration, in: image)
                let value = ResolvedRuntimeSymbol(resolved, image: owner)
                if let match, match.address != value.address {
                    throw RuntimeLookupError(.ambiguousSymbol)
                }
                match = value
            } catch {
                let error = Self.lookupError(error)
                switch error.reason {
                case .symbolMissing: continue
                case .invalidAddress: invalidAddress = true
                default: throw error
                }
            }
        }
        if let match { return match }
        throw RuntimeLookupError(invalidAddress ? .invalidAddress : .symbolMissing)
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

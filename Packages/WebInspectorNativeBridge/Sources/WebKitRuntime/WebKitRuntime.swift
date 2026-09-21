import Foundation
import WebKit
import WebKitRuntimeObjC

/// A loaded image whose path ends with one of the supplied suffixes.
public struct RuntimeImage: Hashable, Sendable {
    public let pathSuffixes: [String]
    public init(pathSuffixes: [String]) { self.pathSuffixes = pathSuffixes }
    public static let webKit = RuntimeImage(pathSuffixes: ["/WebKit.framework/WebKit", "/WebKit.framework/Versions/A/WebKit"])
    public static let javaScriptCore = RuntimeImage(pathSuffixes: ["/JavaScriptCore.framework/JavaScriptCore", "/JavaScriptCore.framework/Versions/A/JavaScriptCore"])
}

/// The identity and storage required by one native operation.
/// Names are alternatives at the same address. Images are tried in order, only when a symbol is absent.
public struct RuntimeSymbol: Hashable, Sendable {
    public enum Name: Hashable, Sendable {
        /// A complete demangled declaration. Punctuation spacing is ignored, but type boundaries are preserved.
        case cxx(String)
        /// An exact Itanium or Mach-O name. Use this when ABI variants share a demangled declaration, such as destructors.
        case mangled(String)
    }
    public enum Kind: Hashable, Sendable { case function, data, vtable }
    public let names: [Name]
    public let images: [RuntimeImage]
    public let kind: Kind
    public init(names: [Name], in images: [RuntimeImage], kind: Kind) {
        self.names = names
        self.images = images
        self.kind = kind
    }
    public init(_ name: Name, in image: RuntimeImage, kind: Kind) {
        self.init(names: [name], in: [image], kind: kind)
    }
}

/// A lookup failure. Descriptions intentionally omit decoded symbols and filesystem paths.
public struct RuntimeLookupError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Reason: String, Sendable { case imageUnavailable, symbolMissing, ambiguousSymbol, invalidAddress, unreadableMemory, pageUnavailable }
    public let reason: Reason
    /// The input index for a failed batch lookup, when applicable.
    public let requestIndex: Int?
    public var description: String { "Runtime lookup failed: \(reason.rawValue)" }
    public var debugDescription: String { description }
    init(_ reason: Reason, requestIndex: Int? = nil) { self.reason = reason; self.requestIndex = requestIndex }
}

/// A symbol in the current process. Resolution validates identity and storage, not its C++ calling convention.
public struct ResolvedRuntimeSymbol: Sendable, Equatable {
    public let address: UInt64
    let imageHeaderAddress: UInt
    let imageUUID: UUID?
    public let image: RuntimeImage
    /// The containing section; this is not the size of the C++ object or function.
    public let sectionRange: Range<UInt64>
    /// The lookup source used for this address, useful for diagnostics.
    public let source: String

    /// Copies bytes starting at the symbol, bounded by its containing section.
    /// Consumers remain responsible for interpreting native layouts and object boundaries.
    public func readBytes(count: Int) throws -> Data {
        guard count >= 0, sectionRange.contains(address), UInt64(count) <= sectionRange.upperBound - address else {
            throw RuntimeLookupError(.invalidAddress)
        }
        guard let data = WKRuntimeReadMemory(UInt(address), UInt(count)) else {
            throw RuntimeLookupError(.unreadableMemory)
        }
        return data
    }
}

/// Shared discovery and page access for features implemented against WebKit's native runtime.
public enum WebKitRuntime {
    /// Resolves the requested symbols in input order, off MainActor, sharing successful results across consumers.
    /// A failed requirement throws with its input index; other resolved requirements remain cached.
    /// This operation does not attach an Inspector frontend or validate consumer-specific ABI layouts.
    public static func resolve(_ symbols: [RuntimeSymbol]) async throws -> [ResolvedRuntimeSymbol] {
        let results = await Task.detached(priority: .userInitiated) {
            RuntimeResolver.resolveCached(symbols)
        }.value
        return try results.enumerated().map { index, result in
            switch result {
            case .success(let symbol): return symbol
            case .failure(let error): throw RuntimeLookupError(error.reason, requestIndex: index)
            }
        }
    }

    /// Borrows the current native page while retaining both its owner and the WKWebView.
    /// The closure is synchronous. The pointer must not escape or be used with an unverified ABI.
    @MainActor
    @unsafe public static func withUnsafePage<Result>(
        of webView: WKWebView,
        _ body: (UnsafeMutableRawPointer, Int) throws -> Result
    ) throws -> Result {
        guard let storage = WKRuntimePageStorage.storage(for: webView) else { throw RuntimeLookupError(.pageUnavailable) }
        let address = unsafe storage.address
        let count = Int(storage.byteCount)
        return try withExtendedLifetime(storage as AnyObject) { try unsafe body(address, count) }
    }

    package static func resolveUncached(_ symbols: [RuntimeSymbol], allowSharedCache: Bool) -> [Swift.Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        let results = RuntimeResolver.resolve(Array(Set(symbols)), allowSharedCache: allowSharedCache)
        return symbols.map { results[$0] ?? .failure(RuntimeLookupError(.symbolMissing)) }
    }

    // Retains the existing synchronous Inspector API without exposing blocking discovery to new consumers.
    package static func resolveSynchronously(_ symbols: [RuntimeSymbol]) -> [Swift.Result<ResolvedRuntimeSymbol, RuntimeLookupError>] {
        RuntimeResolver.resolveCached(symbols)
    }
}

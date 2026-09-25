import Darwin
import Foundation
import Testing
import WebKit
import WebInspectorNativeSymbolFixtures
@testable import WebKitRuntime

struct WebKitRuntimeTests {
    private func fixture() throws -> RuntimeImage {
        var info = unsafe Dl_info()
        let anchor = unsafe unsafeBitCast(WebInspectorNativeSymbolFixtureAnchor as @convention(c) () -> Void, to: UnsafeRawPointer.self)
        try #require(unsafe dladdr(anchor, &info) != 0)
        guard let path = unsafe info.dli_fname else { throw CocoaError(.fileNoSuchFile) }
        return RuntimeImage(pathSuffixes: [unsafe String(cString: path)])
    }
    @Test(arguments: [
        (" WTF :: StringImpl :: deref ( ) ", "_ZN3WTF10StringImpl5derefEv", RuntimeSymbol.Kind.function),
        ("WTF::StringImpl::operator NSString*()", "__ZN3WTF10StringImplcvP8NSStringEv", .function),
        ("vtable  for WebKit :: WebPageDebuggable", "__ZTVN6WebKit17WebPageDebuggableE", .vtable),
    ])
    func declarationsAndExactNamesResolveTheSameFixture(
        _ declaration: String, _ name: String, _ kind: RuntimeSymbol.Kind
    ) async throws {
        let image = try fixture()
        let symbols = try await WebKitRuntime.resolve([
            RuntimeSymbol(.cxx(declaration), in: image, kind: kind),
            RuntimeSymbol(.mangled(name), in: image, kind: kind),
        ])
        #expect(symbols[0] == symbols[1])
    }

    @Test
    func exactLinkerNamesPreserveSignificantUnderscores() async throws {
        let image = try fixture()
        let good = RuntimeSymbol(.mangled("_WebInspectorNativeSymbolFixtureAnchor"), in: image, kind: .function)
        #expect(try await WebKitRuntime.resolve([good]).count == 1)
        for name in ["__WebInspectorNativeSymbolFixtureAnchor", "WebInspectorNativeSymbolFixtureAnchor"] {
            do {
                _ = try await WebKitRuntime.resolve([.init(.mangled(name), in: image, kind: .function)])
                Issue.record("A different linker name unexpectedly resolved.")
            } catch let error as RuntimeLookupError {
                #expect(error.reason == .symbolMissing)
            }
        }
        let cpp = try await WebKitRuntime.resolve([
            .init(.mangled("_ZN3WTF10StringImpl5derefEv"), in: image, kind: .function),
            .init(.mangled("__ZN3WTF10StringImpl5derefEv"), in: image, kind: .function),
        ])
        #expect(cpp[0] == cpp[1])
    }

    @Test
    func resolvesIndependentConsumersAndDoesNotPoisonCacheOnFailure() async throws {
        let image = try fixture()
        let good = RuntimeSymbol(.cxx("WTF::StringImpl::deref()"), in: image, kind: .function)
        let missing = RuntimeSymbol(.cxx("WKRuntimeFixture::missing()"), in: image, kind: .function)
        do {
            _ = try await WebKitRuntime.resolve([good, missing])
            Issue.record("Missing requirement unexpectedly resolved")
        } catch let error as RuntimeLookupError {
            #expect(error.requestIndex == 1)
            #expect(error.reason == .symbolMissing)
            #expect(!String(reflecting: error).contains("WKRuntimeFixture"))
        }
        let first = try await WebKitRuntime.resolve([good])
        let second = try await WebKitRuntime.resolve([good, good])
        #expect(second == [first[0], first[0]])
        #expect(try first[0].readBytes(count: 4).count == 4)
        #expect(throws: RuntimeLookupError.self) {
            try first[0].readBytes(count: Int(first[0].sectionRange.upperBound - first[0].address) + 1)
        }
    }
    @Test
    func ambiguousAlternativesAndWrongStorageAreRejected() async throws {
        let image = try fixture()
        let ambiguous = RuntimeSymbol(names: [.cxx("WTF::StringImpl::deref()"), .cxx("WTF::StringImpl::deref(unsigned int)")], in: [image], kind: .function)
        let wrongStorage = RuntimeSymbol(.cxx("WTF::StringImpl::deref()"), in: image, kind: .data)
        for (symbol, expected) in [(ambiguous, RuntimeLookupError.Reason.ambiguousSymbol), (wrongStorage, .invalidAddress)] {
            do {
                _ = try await WebKitRuntime.resolve([symbol])
                Issue.record("Invalid requirement unexpectedly resolved")
            } catch let error as RuntimeLookupError { #expect(error.reason == expected) }
        }
    }
    @Test
    func imageAlternativesOnlyFallBackWhenMissing() async throws {
        let image = try fixture()
        let missingImage = RuntimeImage(pathSuffixes: ["/not-loaded.framework/not-loaded"])
        let query = RuntimeSymbol(names: [.cxx("WTF::StringImpl::deref()")], in: [missingImage, image], kind: .function)
        let resolved = try await WebKitRuntime.resolve([query])
        #expect(resolved[0].image == image)
        let ambiguous = RuntimeSymbol(names: [.cxx("WTF::StringImpl::deref()"), .cxx("WTF::StringImpl::deref(unsigned int)")], in: [image, .webKit], kind: .function)
        do { _ = try await WebKitRuntime.resolve([ambiguous]); Issue.record("Ambiguity bypassed") }
        catch let error as RuntimeLookupError { #expect(error.reason == .ambiguousSymbol) }
    }
    @Test
    func resolvesDataAndVTableThroughTheSamePublicLookup() async throws {
        let image = try fixture()
        let data = RuntimeSymbol(.cxx("WKRuntimeFixture::value"), in: image, kind: .data)
        let vtable = RuntimeSymbol(.cxx("vtable for WebKit::WebPageDebuggable"), in: image, kind: .vtable)
        let result = try await WebKitRuntime.resolve([data, vtable])
        #expect(try result[0].readBytes(count: 4) == Data([42, 0, 0, 0]))
        #expect(result[1].address != result[0].address)
    }
    @Test @MainActor
    func pageAccessKeepsTheOwnerAliveAndPropagatesClosureErrors() throws {
        let view = WKWebView(frame: .zero)
        enum Expected: Error { case failure }
        let first = try unsafe WebKitRuntime.withUnsafePage(of: view) { pointer, count in
            #expect(count >= MemoryLayout<UInt>.size)
            return UInt(bitPattern: pointer)
        }
        #expect(first != 0)
        do {
            try unsafe WebKitRuntime.withUnsafePage(of: view) { _, _ in throw Expected.failure }
            Issue.record("Closure error was swallowed")
        } catch Expected.failure { }

    }
}

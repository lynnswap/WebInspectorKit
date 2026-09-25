#if os(iOS) || os(macOS)
import Darwin
import Foundation
import Testing
import WebKit
import WebInspectorNativeSymbolFixtures
import WebInspectorNativeBridgeObjC
@testable import WebInspectorNativeBridge
@testable import WebKitRuntime

private let nativeRuntimeSmokeOptInEnvironmentKey = "WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE"
private let shouldRunNativeRuntimeSmokeTests =
    ProcessInfo.processInfo.environment[nativeRuntimeSmokeOptInEnvironmentKey] == "1"
private let nativeRuntimeSmokeDisabledReason: Comment =
    "Native WebKit runtime smoke tests depend on the host WebKit dyld image and shared cache state; set WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE=1 to run them."

@MainActor
private final class NativeSmokeNavigationDelegate: NSObject, WKNavigationDelegate {}

struct NativeInspectorSymbolResolverTests {
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func nativeStringsPreserveUTF8AndEmptyValues() async throws {
        let view = WKWebView(frame: .zero)
        let symbols = try await NativeInspectorResolvedSymbols.resolveCurrent()
        for string in ["", "ASCII", "日本語 😀 e\u{301}", "before\0after", String(repeating: "🦋", count: 2_048)] {
            #expect(unsafe symbols.withObjCSymbols { unsafe WebInspectorNativeRoundTripStringForTesting(string, $0) } == string)
        }
        withExtendedLifetime(view) { }
    }
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason), .timeLimit(.minutes(1)))
    @MainActor
    func nativeFrontendExchangesProtocolMessages() async throws {
        let webView = WKWebView(frame: .zero)
        webView.isInspectable = true
        let bridge = NativeInspectorBridge(webView: webView)
        let (messages, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        bridge.messageHandler = { continuation.yield($0) }
        bridge.fatalFailureHandler = { message in
            continuation.finish(throwing: NSError(
                domain: "NativeFrontendSmokeTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
        defer {
            bridge.detach()
            continuation.finish()
        }

        let symbols = try await NativeInspectorResolvedSymbols.resolveCurrent()
        try bridge.attach(with: symbols)
        do {
            try bridge.sendJSONString("")
            Issue.record("An empty message must fail without invalidating the connection.")
        } catch let error as NativeInspectorBridgeError {
            #expect(error.code == .encodingFailed)
        }
        let commandCount = 32
        for id in 1...commandCount {
            try bridge.sendJSONString("""
                {"id":\(id),"method":"Target.setPauseOnStart","params":{"pauseOnStart":false}}
                """)
        }
        var replies = Set<Int>()
        for try await message in messages {
            let response = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
            guard let id = response?["id"] as? Int, (1...commandCount).contains(id) else { continue }
            #expect(response?["error"] == nil)
            #expect(response?["result"] != nil)
            replies.insert(id)
            if replies.count == commandCount { return }
        }
        Issue.record("The native frontend closed before replying to the protocol command.")
    }
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func detachedNativeAttachmentRejectsCommandsAndRestoresDelegate() async throws {
        let webView = WKWebView(frame: .zero)
        let delegate = NativeSmokeNavigationDelegate()
        webView.navigationDelegate = delegate
        webView.isInspectable = true
        let bridge = NativeInspectorBridge(webView: webView)
        let symbols = try await NativeInspectorResolvedSymbols.resolveCurrent()
        try bridge.attach(with: symbols)
        bridge.detach()
        #expect(webView.navigationDelegate === delegate)

        for _ in 0..<2 {
            do {
                try bridge.sendJSONString(#"{"id":1,"method":"Target.setPauseOnStart"}"#)
                Issue.record("A detached page cannot receive a native command.")
            } catch let error as NativeInspectorBridgeError {
                #expect(error.code == .attachmentInvalidated)
            }
        }
    }

    @Test @MainActor
    func attachmentRejectsNonFunctionHandles() async throws {
        let fixture = try nativeSymbolFixture()
        let symbols = try await NativeInspectorSymbolResolver.resolveUsingFixture(fixture)
        let view = WKWebView(frame: .zero)
        let bridge = WebInspectorNativeBridgeObjC.WebInspectorNativeBridge(webView: view)
        do {
            try unsafe symbols.withObjCSymbols { borrowed in
                var invalid = unsafe borrowed
                unsafe invalid.connectFrontend = borrowed.debuggableVTable
                try unsafe bridge.attach(with: invalid)
            }
            Issue.record("A vtable handle must not become a callable entry point.")
        } catch let error as WebInspectorNativeBridgeError {
            #expect(error.code == .unsupported)
        }
    }

    @Test
    func fixtureResolutionSuppliesValidatedAttachmentInputs() async throws {
        let fixture = try nativeSymbolFixture()
        let resolution = try await NativeInspectorSymbolResolver.resolveUsingFixture(fixture)
        let requirements = NativeInspectorSymbols.current().all.map {
            $0.requirement(webKit: RuntimeImage(pathSuffixes: fixture.pathSuffixes),
                           javaScriptCore: RuntimeImage(pathSuffixes: fixture.pathSuffixes))
        }
        let expected = try await WebKitRuntime.resolveUncached(requirements).map { try $0.get() }
        unsafe resolution.withObjCSymbols { native in
            let handles = unsafe [native.connectFrontend, native.disconnectFrontend, native.stringFromUTF8,
                                  native.stringImplToNSString, native.derefStringImpl,
                                  native.dispatchMessageFromRemote, native.debuggableVTable]
            let addresses = unsafe handles.map { handle in
                unsafe UInt64(UInt(bitPattern: ABIResolvedSymbolAddress(handle!)))
            }
            #expect(addresses == expected.map(\.address))
        }
        #expect(resolution.stringFromUTF8.address == UInt64(WebInspectorNativeSymbolFixtureWTFStringFromUTF8Address()))
        #expect(resolution.stringFromUTF8.source == "loaded-image")
        #expect(resolution.debuggableVTable.source == "loaded-image")
    }
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func nativeSymbolResolutionTiming() async throws {
        try await withWebKitLoaded {
            let cached = try await NativeInspectorSymbolResolver.resolveCurrent()
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                let resolution = try await NativeInspectorSymbolResolver.resolveForTesting()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                #expect(resolution == cached)
            }
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1_000 {
                _ = try await NativeInspectorSymbolResolver.resolveCurrent()
            }
            let cachedMicroseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            print("SYMBOL_RESOLUTION_TIMING uncachedMedianMS=\(samples.sorted()[2]) cachedMeanUS=\(cachedMicroseconds)")
        }
    }
    @Test
    func resolutionPreservesEachFailedRoleAndLookupReason() async throws {
        let fixture = try nativeSymbolFixture()
        let current = NativeInspectorSymbols.current()
        let symbols = current.replacing(
            connectFrontend: NativeInspectorRequiredSymbol(
                role: .connectFrontend, ownerImage: .webKit,
                queries: current.connectFrontend.queries + current.disconnectFrontend.queries,
                resolutionPolicy: .requiredTextSymbol
            ),
            stringFromUTF8: requiredSymbol(
                role: .stringFromUTF8, ownerImage: .javaScriptCore,
                functionName: "definitelyMissingFromUTF8Foo", parameterTypes: [],
                resolutionPolicy: .requiredTextSymbol
            ),
            stringImplToNSString: NativeInspectorRequiredSymbol(
                role: .stringImplToNSString, ownerImage: .javaScriptCore,
                queries: current.stringImplToNSString.queries,
                resolutionPolicy: .requiredDataSymbol
            )
        )
        do {
            _ = try await NativeInspectorSymbolResolver.resolveUsingFixture(fixture, symbols: symbols)
            Issue.record("Failed requirements must not produce attachment inputs.")
        } catch let error as NativeInspectorSymbolResolutionError {
            #expect(error.failures.map(\.role) == [.connectFrontend, .stringFromUTF8, .stringImplToNSString])
            #expect(error.failures.map(\.underlyingError.reason) == [.ambiguousSymbol, .symbolMissing, .invalidAddress])
            #expect(error.diagnostics == [
                "Native Web Inspector requirement connectFrontend failed: ambiguousSymbol.",
                "Native Web Inspector requirement stringFromUTF8 failed: symbolMissing.",
                "Native Web Inspector requirement stringImplToNSString failed: invalidAddress.",
            ])
            let descriptions = String(describing: error) + String(reflecting: error)
            for privateDetail in ["__ZN", "WTF", "WebPageDebuggable", "definitelyMissingFromUTF8Foo"] + fixture.pathSuffixes {
                #expect(!descriptions.contains(privateDetail))
            }
        }
    }
    @Test
    func unavailableImageIsAssociatedWithItsRequirements() async throws {
        let fixture = try nativeSymbolFixture()
        do {
            _ = try await NativeInspectorSymbolResolver.resolveForTesting(
                imagePathSuffixes: fixture.pathSuffixes,
                javaScriptCorePathSuffixes: ["/not-loaded.framework/not-loaded"]
            )
            Issue.record("An unavailable required image must prevent attachment.")
        } catch let error as NativeInspectorSymbolResolutionError {
            #expect(error.failures.map(\.role) == [.stringFromUTF8, .stringImplToNSString])
            #expect(error.failures.map(\.underlyingError.reason) == [.imageUnavailable, .imageUnavailable])
            #expect(!String(reflecting: error).contains("/not-loaded"))
        }
    }
    @Test
    func fixtureSelectsTheRequiredConnectAndStringOverloads() async throws {
        let fixture = try nativeSymbolFixture()
        let resolved = try await NativeInspectorSymbolResolver.resolveUsingFixture(fixture)
        let image = RuntimeImage(pathSuffixes: fixture.pathSuffixes)
        let oracle = try await WebKitRuntime.resolve([
            .init(.mangled("_ZN6WebKit17WebPageDebuggable7connectERN9Inspector15FrontendChannelEbb"), in: image, kind: .function),
            .init(.mangled("_ZN3WTF10StringImpl5derefEv"), in: image, kind: .function),
            .init(.mangled("_ZTVN6WebKit17WebPageDebuggableE"), in: image, kind: .vtable),
        ])
        #expect(resolved.connectFrontend.address == oracle[0].address)
        #expect(resolved.derefStringImpl.address == oracle[1].address)
        #expect(resolved.debuggableVTable.address == oracle[2].address)
        #expect(resolved.stringFromUTF8.address == UInt64(WebInspectorNativeSymbolFixtureWTFStringFromUTF8Address()))
    }

    @Test
    func signatureSpacingPreservesTypeBoundaries() async throws {
        let image = RuntimeImage(pathSuffixes: try nativeSymbolFixture().pathSuffixes)
        let symbols = try await WebKitRuntime.resolve([
            .init(.cxx("WebKit :: WebPageDebuggable :: disconnect ( Inspector :: FrontendChannel & )"), in: image, kind: .function),
            .init(.mangled("_ZN6WebKit17WebPageDebuggable10disconnectERN9Inspector15FrontendChannelE"), in: image, kind: .function),
        ])
        #expect(symbols[0] == symbols[1])
        do {
            _ = try await WebKitRuntime.resolve([
                .init(.cxx("WebKit::WebPageDebuggable::disconnect(Inspector::FrontendChannelconst&)"), in: image, kind: .function),
            ])
            Issue.record("An incompatible type name unexpectedly resolved.")
        } catch let error as RuntimeLookupError {
            #expect(error.reason == .symbolMissing)
        }
    }

    @Test
    func missingDerefIsReportedWithoutUsingTheDestroyEntryPoint() async throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbols.current().replacing(
            derefStringImpl: requiredSymbol(
                role: .derefStringImpl,
                ownerImage: .webKit,
                functionName: "definitelyMissingDeref", parameterTypes: [],
                resolutionPolicy: .requiredTextSymbol
            )
        )
        do {
            _ = try await NativeInspectorSymbolResolver.resolveUsingFixture(fixture, symbols: symbols)
            Issue.record("The destroy entry point cannot replace deref.")
        } catch let error as NativeInspectorSymbolResolutionError {
            #expect(error.failures.map(\.role) == [.derefStringImpl])
            #expect(error.failures.map(\.underlyingError.reason) == [.symbolMissing])
        }
    }
}

private struct NativeSymbolFixture {
    let pathSuffixes: [String]
}

private enum NativeSymbolFixtureError: Error {
    case missingImagePath
}

private func nativeSymbolFixture() throws -> NativeSymbolFixture {
    var info = unsafe Dl_info()
    let anchor = unsafe unsafeBitCast(
        WebInspectorNativeSymbolFixtureAnchor as @convention(c) () -> Void,
        to: UnsafeRawPointer.self
    )
    let didResolveImagePath = unsafe dladdr(anchor, &info) != 0
    try #require(didResolveImagePath)
    guard let imagePath = unsafe info.dli_fname else {
        throw NativeSymbolFixtureError.missingImagePath
    }
    let path = unsafe String(cString: imagePath)
    let imageURL = URL(fileURLWithPath: path)
    return NativeSymbolFixture(
        pathSuffixes: [
            path,
            "\(imageURL.deletingLastPathComponent().lastPathComponent)/\(imageURL.lastPathComponent)",
            imageURL.lastPathComponent,
        ]
    )
}

private extension NativeInspectorSymbolResolver {
    static func resolveUsingFixture(
        _ fixture: NativeSymbolFixture,
        symbols: NativeInspectorSymbols = NativeInspectorSymbols.current()
    ) async throws -> NativeInspectorResolvedSymbols {
        return try await resolveForTesting(
            imagePathSuffixes: fixture.pathSuffixes,
            javaScriptCorePathSuffixes: fixture.pathSuffixes,
            symbols: symbols
        )
    }
}

private extension NativeInspectorSymbols {
    func replacing(
        connectFrontend: NativeInspectorRequiredSymbol? = nil,
        disconnectFrontend: NativeInspectorRequiredSymbol? = nil,
        debuggableVTable: NativeInspectorRequiredSymbol? = nil,
        stringFromUTF8: NativeInspectorRequiredSymbol? = nil,
        stringImplToNSString: NativeInspectorRequiredSymbol? = nil,
        derefStringImpl: NativeInspectorRequiredSymbol? = nil,
        dispatchMessageFromRemote: NativeInspectorRequiredSymbol? = nil
    ) -> NativeInspectorSymbols {
        NativeInspectorSymbols(
            connectFrontend: connectFrontend ?? self.connectFrontend,
            disconnectFrontend: disconnectFrontend ?? self.disconnectFrontend,
            debuggableVTable: debuggableVTable ?? self.debuggableVTable,
            stringFromUTF8: stringFromUTF8 ?? self.stringFromUTF8,
            stringImplToNSString: stringImplToNSString ?? self.stringImplToNSString,
            derefStringImpl: derefStringImpl ?? self.derefStringImpl,
            dispatchMessageFromRemote: dispatchMessageFromRemote ?? self.dispatchMessageFromRemote
        )
    }
}

private func requiredSymbol(
    role: NativeInspectorSymbolRole,
    ownerImage: NativeInspectorSymbolOwnerImage,
    functionName: String,
    parameterTypes: [String],
    resolutionPolicy: NativeInspectorSymbolResolutionPolicy
) -> NativeInspectorRequiredSymbol {
    NativeInspectorRequiredSymbol(
        role: role,
        ownerImage: ownerImage,
        queries: [
            NativeInspectorSymbolQuery(functionName: functionName, parameterTypes: parameterTypes)
        ],
        resolutionPolicy: resolutionPolicy
    )
}

@MainActor
private func withWebKitLoaded<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
    let webView = WKWebView(frame: .zero)
    defer { withExtendedLifetime(webView) { } }
    return try await body()
}

#endif

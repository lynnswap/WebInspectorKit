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

struct NativeInspectorSymbolResolverTests {
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func nativeStringsPreserveUTF8AndEmptyValues() async throws {
        let view = WKWebView(frame: .zero)
        let symbols = try await NativeInspectorResolvedSymbols.resolveCurrentDetached()
        for string in ["", "ASCII", "日本語 😀 e\u{301}", "before\0after", String(repeating: "🦋", count: 2_048)] {
            #expect(WebInspectorNativeRoundTripStringForTesting(string, symbols.objcSymbols) == string)
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

        let symbols = try await NativeInspectorResolvedSymbols.resolveCurrentDetached()
        try bridge.attach(with: symbols)
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
    @Test
    func fixtureImageResolvesCompleteAddressSetDespiteIncompatibleOverloads() throws {
        let fixture = try nativeSymbolFixture()
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(fixture)

        #expect(resolution.failureReason == nil)
        #expect(resolution.addresses.isComplete)
        #expect(resolution.isSupported)
        #expect(resolution.source == "loaded-image")
    }
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func resolveCurrentReturnsCompleteAddressSetOnSupportedPlatforms() throws {
        let resolution = withWebKitLoaded {
            NativeInspectorSymbolResolver.resolveCurrent()
        }

        #expect(resolution.failureReason == nil)
        #expect(resolution.addresses.isComplete)
        #expect(resolution.isSupported)
    }
    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func nativeSymbolResolutionTiming() throws {
        try withWebKitLoaded {
            let cached = NativeInspectorSymbolResolver.resolveCurrent()
            try #require(cached.isSupported)
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                let resolution = NativeInspectorSymbolResolver.resolveForTesting()
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                #expect(resolution.addresses == cached.addresses)
            }
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<1_000 {
                _ = NativeInspectorSymbolResolver.resolveCurrent()
            }
            let cachedMicroseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            print("SYMBOL_RESOLUTION_TIMING uncachedMedianMS=\(samples.sorted()[2]) cachedMeanUS=\(cachedMicroseconds)")
        }
    }
    @Test
    func resolveForTestingReportsOnlyMissingSymbolState() throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbols.current()
            .replacing(
                stringFromUTF8: requiredSymbol(
                    role: .stringFromUTF8,
                    ownerImage: .javaScriptCore,
                    functionName: "definitelyMissingFromUTF8Foo", parameterTypes: [],
                    resolutionPolicy: .requiredTextSymbol
                )
            )
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(
            fixture,
            symbols: symbols
        )
        let failureReason = resolution.failureReason

        #expect(failureReason != nil)
        #expect(resolution.isSupported == false)
        #expect(resolution.addresses == .zero)
        #expect(!resolution.missingFunctions.isEmpty)
        #expect(!resolution.missingFunctions.contains("inspectorTargetAgentVTable"))
        #expect(!resolution.missingFunctions.contains("targetAgentDidCreateFrontendAndBackend"))
        #expect(!resolution.missingFunctions.contains("targetAgentWillDestroyFrontendAndBackend"))
        if let diagnosticsSummary = resolution.diagnosticsSummary {
            #expect(!diagnosticsSummary.contains("attachMode="))
            #expect(!diagnosticsSummary.contains("rootMessaging"))
            #expect(!diagnosticsSummary.contains("pageMessaging"))
        }
        if let failureReason {
            #expect(failureReason.contains("phase="))
            #expect(failureReason.contains("missing="))
            #expect(!failureReason.contains("WebKit"))
            #expect(!failureReason.contains("JavaScriptCore"))
            #expect(!failureReason.contains("WTF"))
            #expect(!failureReason.contains("definitelyMissingFromUTF8Foo"))
            #expect(!failureReason.contains("/System/"))
        }
    }
    @Test
    func fixtureResolutionSelectsUsableStringFromUTF8EntryPoint() throws {
        let fixture = try nativeSymbolFixture()
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(fixture)

        #expect(resolution.isSupported)
        #expect(resolution.stringFromUTF8Address == UInt64(WebInspectorNativeSymbolFixtureWTFStringFromUTF8Address()))
    }
    @Test(arguments: [
        ("RN9Inspector15FrontendChannelEbb", true),
        ("RN9Inspector15FrontendChannelEb", false),
        ("RN9Inspector15FrontendChannelEbbb", false),
        ("RN9Inspector15FrontendChannelEbi", false),
        ("bRN9Inspector15FrontendChannelEb", false),
        ("PN9Inspector15FrontendChannelEbb", false),
        ("RKN9Inspector15FrontendChannelEbb", false),
    ])
    func connectQueryMatchesParameterTypesOrderAndCount(_ parameters: String, _ expected: Bool) {
        let symbol = NativeInspectorSymbols.current().connectFrontend
        let name = "__ZN6WebKit17WebPageDebuggable7connectE" + parameters

        #expect(symbol.matches(symbolName: name) == expected)
        name.withCString { nameC in
            let decodedName = unsafe RuntimeSymbolName.decode(nameC)
            #expect(symbol.matches(decodedName: decodedName) == expected)
        }
    }
    @Test(arguments: [
        ("NSt3__14spanIKDuLm18446744073709551615EEE", true),
        ("NSt3__14spanIKDuLm4EEE", false),
        ("NSt3__14spanIKcLm18446744073709551615EEE", false),
        ("NSt3__14spanIDuLm18446744073709551615EEE", false),
        ("RKNSt3__14spanIKDuLm18446744073709551615EEE", false),
        ("NSt3__14spanIKDuLm18446744073709551615EEEb", false),
    ])
    func stringFactoryQueryMatchesDynamicUTF8SpanByValue(_ parameters: String, _ expected: Bool) {
        let symbol = NativeInspectorSymbols.current().stringFromUTF8
        #expect(symbol.matches(symbolName: "__ZN3WTF6String8fromUTF8E" + parameters) == expected)
    }
    @Test(arguments: ["_", "__"])
    func functionQueriesAcceptItaniumAndMachOSymbolPrefixes(_ prefix: String) {
        let symbols = NativeInspectorSymbols.current()
        #expect(symbols.derefStringImpl.matches(symbolName: prefix + "ZN3WTF10StringImpl5derefEv"))
        #expect(symbols.stringImplToNSString.matches(symbolName: prefix + "ZN3WTF10StringImplcvP8NSStringEv"))
    }
    @Test(arguments: ["", "_", "__", "__Z", "_$s", "_ZN3WTF10StringImpl5derefE"])
    func nonCallableNamesDoNotMatchFunctionQueries(_ name: String) {
        let symbol = NativeInspectorSymbols.current().derefStringImpl
        #expect(!symbol.matches(symbolName: name))
        let decodedName = name.withCString { unsafe RuntimeSymbolName.decode($0) }
        #expect(!symbol.matches(decodedName: decodedName))
    }
    @Test
    func signatureSpacingDoesNotEraseTypeBoundaries() {
        let compact = RuntimeSymbolName.cxxSignatureKey("Inspector::BackendDispatcher::dispatch(WTF::String const&)")
        let spaced = RuntimeSymbolName.cxxSignatureKey("Inspector :: BackendDispatcher :: dispatch ( WTF :: String const & )")
        let otherType = RuntimeSymbolName.cxxSignatureKey("Inspector::BackendDispatcher::dispatch(WTF::Stringconst&)")
        #expect(compact == spaced)
        #expect(compact != otherType)
    }
    @Test
    func stringReleaseQuerySelectsDerefInsteadOfUnconditionalDestruction() {
        let symbol = NativeInspectorSymbols.current().derefStringImpl

        #expect(symbol.matches(symbolName: "__ZN3WTF10StringImpl5derefEv"))
        #expect(!symbol.matches(symbolName: "__ZN3WTF10StringImpl7destroyEPS0_"))
    }
    @Test
    func targetIdentityQueryDistinguishesVTableFromOtherMetadata() {
        let symbol = NativeInspectorSymbols.current().debuggableVTable
        #expect(symbol.matches(symbolName: "__ZTVN6WebKit17WebPageDebuggableE"))
        #expect(!symbol.matches(symbolName: "__ZTIN6WebKit17WebPageDebuggableE"))
        #expect(!symbol.matches(symbolName: "__ZTVN6WebKit26WebPageInspectorControllerE"))
    }
    @Test
    func missingDerefIsReportedWithoutUsingTheDestroyEntryPoint() throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbols.current().replacing(
            derefStringImpl: requiredSymbol(
                role: .derefStringImpl,
                ownerImage: .webKit,
                functionName: "definitelyMissingDeref", parameterTypes: [],
                resolutionPolicy: .requiredTextSymbol
            )
        )
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(fixture, symbols: symbols)

        #expect(!resolution.isSupported)
        #expect(resolution.missingFunctions == ["derefStringImpl"])
    }
    @Test
    func diagnosticsDoNotExposeDecodedMangledSymbols() throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbols.current()
            .replacing(
                stringFromUTF8: requiredSymbol(
                    role: .stringFromUTF8,
                    ownerImage: .javaScriptCore,
                    functionName: "definitelyMissingFromUTF8Foo", parameterTypes: [],
                    resolutionPolicy: .requiredTextSymbol
                )
            )
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(
            fixture,
            symbols: symbols
        )
        let diagnostics = [
            resolution.failureReason,
            resolution.failureKind,
            resolution.phase,
            resolution.source,
            resolution.diagnosticsSummary,
        ].compactMap { $0 }.joined(separator: " ")

        #expect(!diagnostics.contains("__ZN"))
        #expect(!diagnostics.contains("_ZN"))
        #expect(!diagnostics.contains("WTF"))
        #expect(!diagnostics.contains("DefinitelyWrong"))
        #expect(!diagnostics.contains("definitelyMissingFromUTF8Foo"))
    }
}

private extension NativeInspectorRequiredSymbol {
    func matches(symbolName: String) -> Bool {
        RuntimeMatcher(requirement(webKit: .webKit, javaScriptCore: .javaScriptCore)).matches(symbolName)
    }
    func matches(decodedName: RuntimeSymbolName.Decoded) -> Bool {
        queries.contains { RuntimeSymbolName.cxxSignatureKey($0.declaration) == decodedName.cxxFunctionSignature }
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
        allowSharedCacheFallback: Bool = false,
        symbols: NativeInspectorSymbols = NativeInspectorSymbols.current()
    ) throws -> NativeInspectorSymbolResolution {
        return resolveForTesting(
            imagePathSuffixes: fixture.pathSuffixes,
            javaScriptCorePathSuffixes: fixture.pathSuffixes,
            allowSharedCacheFallback: allowSharedCacheFallback,
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
private func withWebKitLoaded<T>(_ body: () throws -> T) rethrows -> T {
    let webView = WKWebView(frame: .zero)
    return try withExtendedLifetime(webView) {
        try body()
    }
}

#endif

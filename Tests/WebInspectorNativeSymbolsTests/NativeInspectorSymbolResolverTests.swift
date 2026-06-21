#if os(iOS) || os(macOS)
import Darwin
import Foundation
import Testing
import WebKit
import WebInspectorNativeSymbolFixtures
@testable import WebInspectorNativeSymbols

private let nativeRuntimeSmokeOptInEnvironmentKey = "WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE"
private let shouldRunNativeRuntimeSmokeTests =
    ProcessInfo.processInfo.environment[nativeRuntimeSmokeOptInEnvironmentKey] == "1"
private let nativeRuntimeSmokeDisabledReason: Comment =
    "Native WebKit runtime smoke tests depend on the host WebKit dyld image and shared cache state; set WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE=1 to run them."

struct NativeInspectorSymbolResolverTests {
    @Test
    func fixtureImageResolvesCompleteAddressSet() throws {
        let fixture = try nativeSymbolFixture()
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(fixture)

        #expect(resolution.failureReason == nil)
        #expect(resolution.addresses.isComplete)
        #expect(resolution.isSupported)
        #expect(resolution.source == "loaded-image")
        #expect(!resolution.usedConnectDisconnectFallback)
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

    @Test
    func resolveForTestingReportsOnlyMissingSymbolState() throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbolResolverCore.currentSymbolQueries()
            .replacing(
                stringFromUTF8: requiredSymbol(
                    role: .stringFromUTF8,
                    ownerImage: .javaScriptCore,
                    requiredNameParts: ["definitelyMissingFromUTF8Foo"],
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
    func resolveForTestingRejectsAmbiguousSemanticMatches() throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbolResolverCore.currentSymbolQueries()
            .replacing(
                stringFromUTF8: requiredSymbol(
                    role: .stringFromUTF8,
                    ownerImage: .javaScriptCore,
                    requiredNameParts: ["WTF::String", "span", "char8_t"],
                    resolutionPolicy: .requiredTextSymbol
                )
            )

        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(
            fixture,
            symbols: symbols
        )

        #expect(!resolution.isSupported)
        #expect(resolution.addresses == .zero)
        #expect(resolution.failureKind == NativeInspectorSymbolFailure.ambiguousSymbolMatch.message)
        #expect(resolution.failureReason?.contains("symbol lookup ambiguous") == true)
        #expect(resolution.missingFunctions.contains("stringFromUTF8"))
    }

    @Test
    func fixtureResolutionSelectsUsableStringFromUTF8EntryPoint() throws {
        let fixture = try nativeSymbolFixture()
        let resolution = try NativeInspectorSymbolResolver.resolveUsingFixture(fixture)

        #expect(resolution.isSupported)
        #expect(resolution.stringFromUTF8Address == UInt64(WebInspectorNativeSymbolFixtureWTFStringFromUTF8Address()))
    }

    @Test
    func cStringSwiftMangledNameDetectionRejectsShortNames() {
        for symbolName in ["", "_", "_$", "$"] {
            let isLikelySwiftMangled = unsafe symbolName.withCString { symbolNameC in
                unsafe NativeInspectorSymbolName.isLikelySwiftMangledName(symbolNameC)
            }

            #expect(!isLikelySwiftMangled)
        }

        let isLikelySwiftMangled = unsafe "_$s".withCString { symbolNameC in
            unsafe NativeInspectorSymbolName.isLikelySwiftMangledName(symbolNameC)
        }

        #expect(isLikelySwiftMangled)
    }

    @Test
    func sharedCacheSymbolFileURLsKeepDirectoryFallbackAfterPreferredCandidate() {
        let preferredPath = "/tmp/nonexistent/dyld_shared_cache_test"
        let fallbackPaths = NativeInspectorSymbolResolver.sharedCacheSymbolFileURLsForTesting(
            activeSharedCachePath: nil
        ).map(\.path)
        let preferredAndFallbackPaths = NativeInspectorSymbolResolver.sharedCacheSymbolFileURLsForTesting(
            activeSharedCachePath: preferredPath
        ).map(\.path)

        #expect(preferredAndFallbackPaths.first == "\(preferredPath).symbols")
        #expect(Array(preferredAndFallbackPaths.dropFirst()) == fallbackPaths)
    }

    @Test
    func sharedCacheSymbolFileURLsDeduplicateActiveSymbolsPath() {
        let activeSymbolsPath = "/System/Library/dyld/dyld_shared_cache_arm64e.symbols"
        let paths = NativeInspectorSymbolResolver.sharedCacheSymbolFileURLsForTesting(
            activeSharedCachePath: activeSymbolsPath
        ).map(\.standardizedFileURL.path)

        #expect(paths.first == activeSymbolsPath)
        #expect(paths.filter { $0 == activeSymbolsPath }.count == 1)
    }

    @Test
    func sharedCacheSymbolFileURLSortsPreferredArchitecturesFirst() {
        #expect(NativeInspectorSymbolResolverCore.sharedCacheSortKey(for: "dyld_shared_cache_arm64e.symbols") == 0)
        #expect(NativeInspectorSymbolResolverCore.sharedCacheSortKey(for: "dyld_shared_cache_arm64.symbols") == 1)
        #expect(NativeInspectorSymbolResolverCore.sharedCacheSortKey(for: "dyld_shared_cache_x86_64.symbols") == 2)
    }

    @Test
    func sharedCacheSourceDescriptionsReportFallbackPartsInOrder() {
        #expect(
            NativeInspectorSymbolResolverCore.sharedCacheSourceDescription(
                base: "full-cache",
                usedConnectDisconnectFallback: false,
                usedRuntimeFallback: false
            ) == "full-cache"
        )
        #expect(
            NativeInspectorSymbolResolverCore.sharedCacheSourceDescription(
                base: "full-cache-file",
                usedConnectDisconnectFallback: true,
                usedRuntimeFallback: true
            ) == "full-cache-file+text-scan+loaded-image-runtime"
        )
    }

    @Test
    func sharedCacheFallbackMergePrefersLaterSuccessfulFullCacheResult() {
        let sharedCacheFailure = NativeInspectorSymbolLookupResult(
            functionAddresses: .zero,
            failureReason: "local symbol lookup unavailable: phase=shared-cache source=shared-cache",
            failureKind: .localSymbolsUnavailable,
            phase: .sharedCache,
            missingFunctions: [],
            source: "shared-cache",
            usedConnectDisconnectFallback: false
        )
        let fullCacheSuccess = NativeInspectorSymbolLookupResult(
            functionAddresses: completeNativeInspectorSymbolAddresses,
            failureReason: nil,
            failureKind: nil,
            phase: .fullCache,
            missingFunctions: [],
            source: "full-cache",
            usedConnectDisconnectFallback: false
        )

        let merged = NativeInspectorSymbolResolverCore.mergedResolution(
            preferred: sharedCacheFailure,
            fallback: fullCacheSuccess
        )

        #expect(merged.failureReason == nil)
        #expect(merged.phase == .fullCache)
        #expect(merged.source == "full-cache")
        #expect(merged.functionAddresses == completeNativeInspectorSymbolAddresses)
    }

    @Test
    func imagePathSuffixesMatchExpectedFrameworkLocations() {
        let suffixes = NativeInspectorSymbolResolver.imagePathSuffixesForTesting()

        #expect(suffixes.webKit == [
            "/System/Library/Frameworks/WebKit.framework/WebKit",
            "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
        ])
        #expect(suffixes.javaScriptCore == [
            "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
            "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore",
        ])
        #expect(suffixes.webCore == [
            "/System/Library/PrivateFrameworks/WebCore.framework/WebCore",
            "/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore",
        ])
    }

    @Test(.disabled(if: !shouldRunNativeRuntimeSmokeTests, nativeRuntimeSmokeDisabledReason))
    @MainActor
    func resolvedAddressHeaderValidationAcceptsMatchingImageAndRejectsUnexpectedImage() throws {
        let (resolution, headers) = try withWebKitLoaded {
            (
                NativeInspectorSymbolResolver.resolveCurrent(),
                try #require(NativeInspectorSymbolResolver.loadedImageHeaderAddressesForTesting())
            )
        }

        #expect(
            NativeInspectorSymbolResolver.resolvedAddressMatchesExpectedImageForTesting(
                resolution.connectFrontendAddress,
                expectedHeaderAddresses: [headers.webKit]
            )
        )
        #expect(
            !NativeInspectorSymbolResolver.resolvedAddressMatchesExpectedImageForTesting(
                resolution.connectFrontendAddress,
                expectedHeaderAddresses: [headers.javaScriptCore]
            )
        )
    }

    @Test
    func fallbackCallTargetScannerReturnsUniqueFunctionStart() throws {
        #if arch(arm64) || arch(arm64e)
        let textBaseAddress: UInt64 = 0x1000
        let functionStarts: [UInt64] = [textBaseAddress, textBaseAddress + 0x10]
        let targetAddress: UInt64 = textBaseAddress + 0x40
        let words: [UInt32] = [
            0xD503201F,
            encodeARM64BL(from: textBaseAddress + 4, to: targetAddress),
            0xD503201F,
            0xD65F03C0,
            0xD503201F,
            0xD503201F,
            0xD503201F,
            0xD65F03C0,
        ]
        let bytes = arm64TextBytes(from: words)

        let functionStart = unsafe bytes.withUnsafeBufferPointer { rawBytes in
            unsafe NativeInspectorSymbolResolver.uniqueFunctionStartContainingCallTargetsForTesting(
                architecture: "arm64",
                textBaseAddress: textBaseAddress,
                textPointer: rawBytes.baseAddress!,
                textSize: bytes.count,
                functionStartAddresses: functionStarts,
                callTargetAddresses: [targetAddress]
            )
        }

        #expect(functionStart == textBaseAddress)
        #else
        throw Skip("This synthetic scanner test is only implemented for ARM64 layouts.")
        #endif
    }

    @Test
    func fallbackCallTargetScannerRejectsAmbiguousFunctions() throws {
        #if arch(arm64) || arch(arm64e)
        let textBaseAddress: UInt64 = 0x2000
        let functionStarts: [UInt64] = [textBaseAddress, textBaseAddress + 0x10]
        let targetAddress: UInt64 = textBaseAddress + 0x40
        let words: [UInt32] = [
            encodeARM64BL(from: textBaseAddress, to: targetAddress),
            0xD503201F,
            0xD503201F,
            0xD65F03C0,
            encodeARM64BL(from: textBaseAddress + 0x10, to: targetAddress),
            0xD503201F,
            0xD503201F,
            0xD65F03C0,
        ]
        let bytes = arm64TextBytes(from: words)

        let functionStart = unsafe bytes.withUnsafeBufferPointer { rawBytes in
            unsafe NativeInspectorSymbolResolver.uniqueFunctionStartContainingCallTargetsForTesting(
                architecture: "arm64",
                textBaseAddress: textBaseAddress,
                textPointer: rawBytes.baseAddress!,
                textSize: bytes.count,
                functionStartAddresses: functionStarts,
                callTargetAddresses: [targetAddress]
            )
        }

        #expect(functionStart == nil)
        #else
        throw Skip("This synthetic scanner test is only implemented for ARM64 layouts.")
        #endif
    }

    @Test
    func diagnosticsDoNotExposeDecodedMangledSymbols() throws {
        let fixture = try nativeSymbolFixture()
        let symbols = NativeInspectorSymbolResolverCore.currentSymbolQueries()
            .replacing(
                stringFromUTF8: requiredSymbol(
                    role: .stringFromUTF8,
                    ownerImage: .javaScriptCore,
                    requiredNameParts: ["definitelyMissingFromUTF8Foo"],
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

    @Test
    func fullCacheFallbackDiagnosticsRemainRedacted() {
        let source = NativeInspectorSymbolResolverCore.sharedCacheSourceDescription(
            base: "full-cache-file",
            usedConnectDisconnectFallback: true,
            usedRuntimeFallback: true
        )
        let reason = NativeInspectorSymbolResolverCore.formattedFailureReason(
            kind: .runtimeFunctionSymbolMissing,
            detail: nil,
            phase: .fullCacheFile,
            source: source,
            missingFunctions: ["connectFrontend", "stringFromUTF8"],
            usedConnectDisconnectFallback: true
        )

        #expect(reason.contains("phase=full-cache-file"))
        #expect(reason.contains("source=full-cache-file+text-scan+loaded-image-runtime"))
        #expect(reason.contains("missing=connectFrontend,stringFromUTF8"))
        #expect(reason.contains("textScanFallback=true"))
        #expect(!reason.contains("__ZN"))
        #expect(!reason.contains("_ZN"))
        #expect(!reason.contains("WTF"))
        #expect(!reason.contains("/System/"))
    }

}

private let completeNativeInspectorSymbolAddresses = NativeInspectorSymbolAddresses(
    connectFrontendAddress: 0x1_0000,
    disconnectFrontendAddress: 0x1_0100,
    stringFromUTF8Address: 0x2_0000,
    stringImplToNSStringAddress: 0x2_0100,
    destroyStringImplAddress: 0x2_0200,
    backendDispatcherDispatchAddress: 0x1_0200
)

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
        symbols: NativeInspectorSymbols = NativeInspectorSymbolResolverCore.currentSymbolQueries()
    ) throws -> NativeInspectorSymbolResolution {
        return resolveForTesting(
            imagePathSuffixes: fixture.pathSuffixes,
            javaScriptCorePathSuffixes: fixture.pathSuffixes,
            webCorePathSuffixes: fixture.pathSuffixes,
            allowSharedCacheFallback: allowSharedCacheFallback,
            symbols: symbols
        )
    }
}

private extension NativeInspectorSymbols {
    func replacing(
        connectFrontend: NativeInspectorRequiredSymbol? = nil,
        disconnectFrontend: NativeInspectorRequiredSymbol? = nil,
        inspectorControllerConnectTargets: NativeInspectorRequiredSymbol? = nil,
        inspectorControllerDisconnectTargets: NativeInspectorRequiredSymbol? = nil,
        stringFromUTF8: NativeInspectorRequiredSymbol? = nil,
        stringImplToNSString: NativeInspectorRequiredSymbol? = nil,
        destroyStringImpl: NativeInspectorRequiredSymbol? = nil,
        backendDispatcherDispatch: NativeInspectorRequiredSymbol? = nil
    ) -> NativeInspectorSymbols {
        NativeInspectorSymbols(
            connectFrontend: connectFrontend ?? self.connectFrontend,
            disconnectFrontend: disconnectFrontend ?? self.disconnectFrontend,
            inspectorControllerConnectTargets: inspectorControllerConnectTargets ?? self.inspectorControllerConnectTargets,
            inspectorControllerDisconnectTargets: inspectorControllerDisconnectTargets ?? self.inspectorControllerDisconnectTargets,
            stringFromUTF8: stringFromUTF8 ?? self.stringFromUTF8,
            stringImplToNSString: stringImplToNSString ?? self.stringImplToNSString,
            destroyStringImpl: destroyStringImpl ?? self.destroyStringImpl,
            backendDispatcherDispatch: backendDispatcherDispatch ?? self.backendDispatcherDispatch
        )
    }
}

private func requiredSymbol(
    role: NativeInspectorSymbolRole,
    ownerImage: NativeInspectorSymbolOwnerImage,
    requiredNameParts: [String],
    resolutionPolicy: NativeInspectorSymbolResolutionPolicy
) -> NativeInspectorRequiredSymbol {
    NativeInspectorRequiredSymbol(
        role: role,
        ownerImage: ownerImage,
        queries: [
            NativeInspectorSymbolQuery(requiredNameParts: requiredNameParts)
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

#if arch(arm64) || arch(arm64e)
private func encodeARM64BL(from instructionAddress: UInt64, to targetAddress: UInt64) -> UInt32 {
    let delta = Int64(targetAddress) - Int64(instructionAddress)
    let immediate = UInt32(bitPattern: Int32(delta >> 2)) & 0x03FF_FFFF
    return 0x9400_0000 | immediate
}

private func arm64TextBytes(from words: [UInt32]) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(words.count * MemoryLayout<UInt32>.size)
    for word in words {
        let encoded = word.littleEndian
        bytes.append(UInt8(truncatingIfNeeded: encoded))
        bytes.append(UInt8(truncatingIfNeeded: encoded >> 8))
        bytes.append(UInt8(truncatingIfNeeded: encoded >> 16))
        bytes.append(UInt8(truncatingIfNeeded: encoded >> 24))
    }
    return bytes
}
#endif
#endif

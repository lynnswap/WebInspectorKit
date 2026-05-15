#if os(iOS) || os(macOS)
import Foundation
import Testing
import WebKit
@testable import WebInspectorNativeSymbols

struct NativeInspectorSymbolResolverTests {
    @Test
    @MainActor
    func machOKitLookupProvidesSharedCacheAndLoadedImages() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        let (currentSharedCache, webKitImage, javaScriptCoreImage) = withWebKitLoaded {
            (
                unsafe MachOKitSymbolLookup.currentSharedCache,
                unsafe MachOKitSymbolLookup.loadedImage(
                    matching: NativeInspectorSymbolResolver.imagePathSuffixesForTesting().webKit
                ),
                unsafe MachOKitSymbolLookup.loadedImage(
                    matching: NativeInspectorSymbolResolver.imagePathSuffixesForTesting().javaScriptCore
                )
            )
        }
        #expect(currentSharedCache != nil)
        #expect(webKitImage != nil)
        #expect(javaScriptCoreImage != nil)
        #endif
    }

    @Test
    @MainActor
    func resolveCurrentReturnsCompleteAddressSetOnSupportedPlatforms() throws {
        let resolution = withWebKitLoaded {
            NativeInspectorSymbolResolver.resolveCurrent()
        }

        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        #expect(resolution.failureReason == nil)
        #expect(resolution.addresses.isComplete)
        #expect(resolution.isSupported)
        #endif
    }

    @Test
    @MainActor
    func resolveForTestingReportsOnlyMissingSymbolState() {
        let resolution = withWebKitLoaded {
            NativeInspectorSymbolResolver.resolveForTesting(
                stringFromUTF8Symbol: obfuscated(["Ev", "27definitelyMissingFromUTF8Foo", "6String", "3WTF", "__ZN"])
            )
        }
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
    @MainActor
    func resolveForTestingUsesAlternateConnectDisconnectCandidates() throws {
        let primaryConnect = try #require(NativeInspectorSymbolResolver.connectSymbolsForTesting().first)
        let primaryDisconnect = try #require(NativeInspectorSymbolResolver.disconnectSymbolsForTesting().first)

        let resolution = withWebKitLoaded {
            NativeInspectorSymbolResolver.resolveForTesting(
                connectSymbol: obfuscated(["Ev", "26DefinitelyWrongConnectName", "7Missing", "__ZN"]),
                disconnectSymbol: obfuscated(["Ev", "29DefinitelyWrongDisconnectName", "7Missing", "__ZN"]),
                alternateConnectSymbols: [primaryConnect],
                alternateDisconnectSymbols: [primaryDisconnect]
            )
        }

        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        #expect(resolution.isSupported)
        #expect(resolution.connectFrontendAddress != 0)
        #expect(resolution.disconnectFrontendAddress != 0)
        #endif
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

    @Test
    @MainActor
    func resolvedAddressHeaderValidationAcceptsMatchingImageAndRejectsUnexpectedImage() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
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
        #endif
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
    @MainActor
    func diagnosticsDoNotExposeDecodedMangledSymbols() {
        let resolution = withWebKitLoaded {
            NativeInspectorSymbolResolver.resolveForTesting(
                stringFromUTF8Symbol: obfuscated(["Ev", "27definitelyMissingFromUTF8Foo", "6String", "3WTF", "__ZN"])
            )
        }
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
    func buildProductDoesNotContainPlainSensitiveMangledSymbols() throws {
        let candidates = testExecutableCandidates()
        guard !candidates.isEmpty else {
            #expect(!candidates.isEmpty)
            return
        }

        let sensitiveSymbols = NativeInspectorSymbolResolver.sensitiveSymbolsForBinarySafetyTesting()
            .map { Data($0.decodedString().utf8) }

        for candidate in candidates {
            let data = try Data(contentsOf: candidate)
            for symbolData in sensitiveSymbols {
                #expect(data.range(of: symbolData) == nil)
            }
        }
    }
}

@MainActor
private func withWebKitLoaded<T>(_ body: () throws -> T) rethrows -> T {
    let webView = WKWebView(frame: .zero)
    return try withExtendedLifetime(webView) {
        try body()
    }
}

private func obfuscated(_ reverseTokens: [String]) -> ObfuscatedSymbolName {
    obfuscated(reverseTokens.reversed().joined())
}

private func obfuscated(_ string: String) -> ObfuscatedSymbolName {
    let key: UInt8 = 0xB3
    return ObfuscatedSymbolName(
        key: key,
        encodedBytes: string.utf8.map { $0 ^ key }
    )
}

private func testExecutableCandidates() -> [URL] {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let repoRoot = sourceURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = repoRoot.appendingPathComponent(".build")
    guard let enumerator = FileManager.default.enumerator(
        at: buildDirectory,
        includingPropertiesForKeys: nil
    ) else {
        return []
    }

    return enumerator
        .compactMap { $0 as? URL }
        .filter { $0.path.hasSuffix("WebInspectorKitPackageTests.xctest/Contents/MacOS/WebInspectorKitPackageTests") }
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

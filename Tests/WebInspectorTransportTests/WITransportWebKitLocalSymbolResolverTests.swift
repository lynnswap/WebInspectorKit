#if os(iOS) || os(macOS)
import Foundation
import Testing
@testable import WebInspectorTransport

struct WITransportNativeInspectorSymbolResolverTests {
    @Test
    func dyldRuntimeResolvesRequiredSymbols() {
        let hasSharedCacheRange = unsafe WITransportDyldRuntime.sharedCacheRange() != nil
        let hasContainingHeader = unsafe WITransportDyldRuntime.imageHeader(containing: #dsohandle) != nil
        let sharedCacheFilePath = unsafe WITransportDyldRuntime.sharedCacheFilePath()

        #expect(hasSharedCacheRange)
        #expect(hasContainingHeader)
        if let sharedCacheFilePath {
            #expect(!sharedCacheFilePath.isEmpty)
        }
    }

    @Test
    func resolveCurrentWebKitAttachSymbolsReturnsAddressesOnSupportedPlatforms() throws {
        let resolution = WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        #expect(resolution.failureReason == nil)
        #expect(resolution.connectFrontendAddress != 0)
        #expect(resolution.disconnectFrontendAddress != 0)
        #expect(resolution.stringFromUTF8Address != 0)
        #expect(resolution.stringImplToNSStringAddress != 0)
        #expect(resolution.destroyStringImplAddress != 0)
        #expect(resolution.backendDispatcherDispatchAddress != 0)
        #expect(resolution.supportSnapshot.isSupported)
        #expect(!resolution.supportSnapshot.capabilities.contains(.networkBootstrapSnapshot))
        #if os(iOS)
        #expect(resolution.backendKind == .iOSNativeInspector)
        #elseif os(macOS)
        #expect(resolution.backendKind == .macOSNativeInspector)
        #endif
        #endif
    }

    @Test
    func resolveForTestingReportsFailureReasonForMissingSymbol() {
        let resolution = WITransportNativeInspectorSymbolResolver.resolveForTesting(
            // __ZN3WTF6String27definitelyMissingFromUTF8FooEv
            stringFromUTF8Symbol: mangled(["Ev", "27definitelyMissingFromUTF8Foo", "6String", "3WTF", "__ZN"])
        )
        let failureReason = resolution.failureReason

        #expect(failureReason != nil)
        #expect(resolution.connectFrontendAddress == 0)
        #expect(resolution.disconnectFrontendAddress == 0)
        #expect(resolution.stringFromUTF8Address == 0)
        #expect(resolution.stringImplToNSStringAddress == 0)
        #expect(resolution.destroyStringImplAddress == 0)
        #expect(resolution.backendDispatcherDispatchAddress == 0)
        #expect(resolution.supportSnapshot.isSupported == false)
        #expect(resolution.phase != nil)
        #expect(!resolution.missingFunctions.isEmpty)
        #expect(!resolution.missingFunctions.contains("inspectorTargetAgentVTable"))
        #expect(!resolution.missingFunctions.contains("targetAgentDidCreateFrontendAndBackend"))
        #expect(!resolution.missingFunctions.contains("targetAgentWillDestroyFrontendAndBackend"))
        if let diagnosticsSummary = resolution.diagnosticsSummary {
            #expect(!diagnosticsSummary.contains("attachMode="))
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
    func resolveForTestingUsesAlternateConnectDisconnectCandidates() throws {
        let connectSymbols = WITransportNativeInspectorSymbolResolver.connectSymbolsForTesting()
        let disconnectSymbols = WITransportNativeInspectorSymbolResolver.disconnectSymbolsForTesting()
        let primaryConnect = try #require(connectSymbols.first)
        let primaryDisconnect = try #require(disconnectSymbols.first)

        let resolution = WITransportNativeInspectorSymbolResolver.resolveForTesting(
            // __ZN7Missing26DefinitelyWrongConnectNameEv
            connectSymbol: mangled(["Ev", "26DefinitelyWrongConnectName", "7Missing", "__ZN"]),
            // __ZN7Missing29DefinitelyWrongDisconnectNameEv
            disconnectSymbol: mangled(["Ev", "29DefinitelyWrongDisconnectName", "7Missing", "__ZN"]),
            alternateConnectSymbols: [primaryConnect],
            alternateDisconnectSymbols: [primaryDisconnect]
        )

        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        #expect(resolution.supportSnapshot.isSupported)
        #expect(resolution.connectFrontendAddress != 0)
        #expect(resolution.disconnectFrontendAddress != 0)
        #endif
    }

    @Test
    func sharedCacheSymbolFileURLsKeepDirectoryFallbackAfterPreferredCandidate() {
        let preferredPath = "/tmp/nonexistent/dyld_shared_cache_test"
        let fallbackPaths = WITransportNativeInspectorSymbolResolver.sharedCacheSymbolFileURLsForTesting(
            activeSharedCachePath: nil
        ).map(\.path)
        let preferredAndFallbackPaths = WITransportNativeInspectorSymbolResolver.sharedCacheSymbolFileURLsForTesting(
            activeSharedCachePath: preferredPath
        ).map(\.path)

        #expect(preferredAndFallbackPaths.first == "\(preferredPath).symbols")
        #expect(Array(preferredAndFallbackPaths.dropFirst()) == fallbackPaths)
    }

    @Test
    func imagePathSuffixesMatchExpectedFrameworkLocations() {
        let suffixes = WITransportNativeInspectorSymbolResolver.imagePathSuffixesForTesting()

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
    func resolvedAddressHeaderValidationAcceptsMatchingImageAndRejectsUnexpectedImage() throws {
        let resolution = WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        let headers = try #require(
            WITransportNativeInspectorSymbolResolver.loadedImageHeaderAddressesForTesting()
        )

        #expect(
            WITransportNativeInspectorSymbolResolver.resolvedAddressMatchesExpectedImageForTesting(
                resolution.connectFrontendAddress,
                expectedHeaderAddresses: [headers.webKit]
            )
        )
        #expect(
            !WITransportNativeInspectorSymbolResolver.resolvedAddressMatchesExpectedImageForTesting(
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
            unsafe WITransportNativeInspectorSymbolResolver.uniqueFunctionStartContainingCallTargetsForTesting(
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
            unsafe WITransportNativeInspectorSymbolResolver.uniqueFunctionStartContainingCallTargetsForTesting(
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
}

private func mangled(_ reverseTokens: [String]) -> String {
    reverseTokens.reversed().joined()
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

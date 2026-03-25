#if os(iOS) || os(macOS)
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
        #expect(resolution.supportSnapshot.capabilities.contains(.networkBootstrapSnapshot))
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
            stringFromUTF8Symbol: "__ZN3WTF6String27definitelyMissingFromUTF8FooEv"
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
        if let failureReason {
            #expect(!failureReason.contains("WebKit"))
            #expect(!failureReason.contains("JavaScriptCore"))
            #expect(!failureReason.contains("WTF"))
            #expect(!failureReason.contains("definitelyMissingFromUTF8Foo"))
            #expect(!failureReason.contains("/System/"))
        }
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
}
#endif

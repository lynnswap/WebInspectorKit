#if os(iOS) || os(macOS)
import Testing
@testable import WebInspectorTransport

struct WITransportNativeInspectorSymbolResolverTests {
    @Test
    func resolveCurrentWebKitAttachSymbolsReturnsAddressesOnSupportedPlatforms() throws {
        let resolution = WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        #expect(resolution.failureReason == nil)
        #expect(resolution.connectFrontendAddress != 0)
        #expect(resolution.disconnectFrontendAddress != 0)
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
            connectSymbol: "__ZN6WebKit26WebPageInspectorController27definitelyMissingConnectFooEv",
            disconnectSymbol: "__ZN6WebKit26WebPageInspectorController30definitelyMissingDisconnectBarEv"
        )

        #expect(resolution.failureReason != nil)
        #expect(resolution.connectFrontendAddress == 0)
        #expect(resolution.disconnectFrontendAddress == 0)
        #expect(resolution.supportSnapshot.isSupported == false)
    }
}
#endif

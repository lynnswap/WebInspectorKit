#if os(iOS)
import Testing
@testable import WebInspectorTransport

struct WITransportWebKitLocalSymbolResolverTests {
    @Test
    func resolveCurrentWebKitAttachSymbolsReturnsAddressesOnSimulator() throws {
        #if targetEnvironment(simulator)
        let resolution = WITransportWebKitLocalSymbolResolver.currentAttachResolution()
        #expect(resolution.failureReason == nil)
        #expect(resolution.connectFrontendAddress != 0)
        #expect(resolution.disconnectFrontendAddress != 0)
        #else
        throw Skip("This smoke test only runs on the iOS simulator.")
        #endif
    }

    @Test
    func resolveForTestingReportsFailureReasonForMissingSymbol() {
        let resolution = WITransportWebKitLocalSymbolResolver.resolveForTesting(
            connectSymbol: "__ZN6WebKit26WebPageInspectorController27definitelyMissingConnectFooEv",
            disconnectSymbol: "__ZN6WebKit26WebPageInspectorController30definitelyMissingDisconnectBarEv"
        )

        #expect(resolution.failureReason != nil)
        #expect(resolution.connectFrontendAddress == 0)
        #expect(resolution.disconnectFrontendAddress == 0)
    }
}
#endif

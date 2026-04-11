import Testing
@testable import WebInspectorEngine
@testable import WebInspectorTransport

@MainActor
struct WIBackendFactoryTests {
    @Test
    func makeNetworkBackendFallsBackToPageAgentWhenTransportIsUnsupported() {
        let backend = WIBackendFactory.makeNetworkBackend(
            configuration: .init(),
            supportSnapshot: .unsupported(reason: "test")
        )

        #expect(String(describing: type(of: backend)) == "NetworkPageAgent")
        #expect(backend.support.isSupported)
    }

    @Test
    func makeNetworkBackendUsesTransportDriverWhenTransportIsSupported() {
        let backend = WIBackendFactory.makeNetworkBackend(
            configuration: .init(),
            supportSnapshot: .supported(
                backendKind: .iOSNativeInspector,
                capabilities: [.networkDomain]
            )
        )

        #expect(String(describing: type(of: backend)) == "NetworkTransportDriver")
    }

    @Test
    func makeConsoleBackendUsesTransportDriverEvenWhenTransportIsUnsupported() {
        let backend = WIBackendFactory.makeConsoleBackend(
            supportSnapshot: .unsupported(reason: "test")
        )

        #expect(String(describing: type(of: backend)) == "ConsoleTransportDriver")
        #expect(backend.support.isSupported == false)
    }
}

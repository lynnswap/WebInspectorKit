import Testing
import WebKit
@testable import WebInspectorEngine
@_spi(Monocly) @testable import WebInspectorTransport

@MainActor
struct WIBackendFactoryTests {
    @Test
    func makeNetworkBackendReturnsUnsupportedBackendWhenTransportIsUnsupported() {
        let backend = WIBackendFactory.makeNetworkBackend(
            configuration: .init(),
            supportSnapshot: .unsupported(reason: "test")
        )

        #expect(String(describing: type(of: backend)) == "WINetworkUnsupportedBackend")
        #expect(backend.support.isSupported == false)
        #expect(backend.support.failureReason == "test")
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
    func supportSnapshotOverrideWinsOverInjectedSupportedSnapshot() {
        let backend = WIBackendFactoryTesting.withNetworkSupportSnapshotOverride(
            .unsupported(reason: "override")
        ) {
            WIBackendFactory.makeNetworkBackend(
                configuration: .init(),
                supportSnapshot: .supported(
                    backendKind: .iOSNativeInspector,
                    capabilities: [.networkDomain]
                )
            )
        }

        #expect(String(describing: type(of: backend)) == "WINetworkUnsupportedBackend")
        #expect(backend.support.failureReason == "override")
    }

    @Test
    func unsupportedNetworkBackendKeepsEmptyStoreAndReportsAgentUnavailable() async {
        let backend = WIBackendFactory.makeNetworkBackend(
            configuration: .init(),
            supportSnapshot: .unsupported(reason: "test")
        )

        #expect(backend.store.isRecording)
        await backend.setMode(.active)
        await backend.attachPageWebView(WKWebView(frame: .zero))

        #expect(backend.webView == nil)
        #expect(backend.store.entries.isEmpty)

        backend.store.applySnapshots([makeSnapshot(requestID: 1)])
        #expect(backend.store.entries.count == 1)
        await backend.clearNetworkLogs()
        #expect(backend.store.entries.isEmpty)
        #expect(backend.store.isRecording)

        backend.store.applySnapshots([makeSnapshot(requestID: 2)])
        await backend.detachPageWebView(preparing: .stopped)
        #expect(backend.store.entries.isEmpty)
        #expect(backend.store.isRecording == false)

        await backend.setMode(.active)
        #expect(backend.store.isRecording)
        #expect(backend.supportsDeferredLoading(for: .response) == false)

        let result = await backend.fetchBodyResult(
            locator: .networkRequest(id: "request-1", targetIdentifier: nil),
            role: .response
        )
        guard case .agentUnavailable = result else {
            Issue.record("Expected unsupported backend body fetch to return agentUnavailable.")
            return
        }
    }
}

private func makeSnapshot(requestID: Int) -> NetworkEntry.Snapshot {
    NetworkEntry.Snapshot(
        sessionID: "session",
        requestID: requestID,
        request: NetworkEntry.Request(
            url: "https://example.com/\(requestID)",
            method: "GET",
            headers: NetworkHeaders(),
            body: nil,
            bodyBytesSent: nil,
            type: "Document",
            wallTime: nil
        ),
        response: NetworkEntry.Response(
            statusCode: nil,
            statusText: "",
            mimeType: nil,
            headers: NetworkHeaders(),
            body: nil,
            blockedCookies: [],
            errorDescription: nil
        ),
        transfer: NetworkEntry.Transfer(
            startTimestamp: 0,
            endTimestamp: nil,
            duration: nil,
            encodedBodyLength: nil,
            decodedBodyLength: nil,
            phase: .pending
        )
    )
}

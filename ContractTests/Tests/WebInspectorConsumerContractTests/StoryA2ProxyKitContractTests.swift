import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func webInspectorProxyPublicLifecycleAndCommandSurfaceWorksFromConsumerPackage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    guard case .page = target.kind else {
        Issue.record("Expected WebInspectorProxyTestRuntime to install a page target.")
        return
    }
    #expect(await runtime.proxy.canReload)

    await runtime.backend.enqueue((), for: "Network", method: "enable")
    try await target.network.enable()

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "enable")))
    #expect(commands.first?.targetID == target.id)

    await runtime.proxy.close()
    try await runtime.proxy.waitUntilClosed()
    #expect(await runtime.proxy.canReload == false)
}

@Test
func webInspectorProxyNetworkEventsMulticastToConsumerSubscribers() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    var firstEvents = target.network.events.makeAsyncIterator()
    var secondEvents = target.network.events.makeAsyncIterator()

    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 2)

    await runtime.backend.emit(
        .responseReceived(
            id: WebInspectorProxyTestFixtures.networkRequestID("contract-multicast-request"),
            response: Network.Response(status: 204, mimeType: "application/json"),
            resourceType: .fetch,
            timestamp: 42
        ),
        target: target
    )

    let firstEvent = try #require(await firstEvents.next())
    let secondEvent = try #require(await secondEvents.next())

    guard case let .responseReceived(firstID, firstResponse, firstType, firstTimestamp) = firstEvent else {
        Issue.record("Expected the first subscriber to receive Network.responseReceived.")
        return
    }
    guard case let .responseReceived(secondID, secondResponse, secondType, secondTimestamp) = secondEvent else {
        Issue.record("Expected the second subscriber to receive Network.responseReceived.")
        return
    }

    let expectedID = WebInspectorProxyTestFixtures.networkRequestID("contract-multicast-request")
    #expect(firstID == expectedID)
    #expect(secondID == expectedID)
    #expect(firstResponse.status == 204)
    #expect(secondResponse.status == 204)
    #expect(firstType == .fetch)
    #expect(secondType == .fetch)
    #expect(firstTimestamp == 42)
    #expect(secondTimestamp == 42)
}

@Test
func webInspectorProxySecurityMetadataIsConstructibleAndReadableByConsumers() {
    let validFrom = Date(timeIntervalSince1970: 1_700_000_000)
    let validUntil = Date(timeIntervalSince1970: 1_800_000_000)
    let security = Network.Security(
        connection: Network.Security.Connection(
            tlsProtocol: "TLS 1.3",
            cipher: "AES_128_GCM_SHA256"
        ),
        certificate: Network.Security.Certificate(
            subject: "example.com",
            validFrom: validFrom,
            validUntil: validUntil,
            dnsNames: ["example.com"],
            ipAddresses: []
        )
    )
    let response = Network.Response(security: security)
    let metrics = Network.Metrics(
        securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
    )

    #expect(response.security?.connection?.tlsProtocol == "TLS 1.3")
    #expect(response.security?.connection?.cipher == "AES_128_GCM_SHA256")
    #expect(response.security?.certificate?.subject == "example.com")
    #expect(response.security?.certificate?.validFrom == validFrom)
    #expect(response.security?.certificate?.validUntil == validUntil)
    #expect(response.security?.certificate?.dnsNames == ["example.com"])
    #expect(response.security?.certificate?.ipAddresses == [])
    #expect(metrics.securityConnection?.tlsProtocol == "TLS 1.3")
}

@Test
func webInspectorProxyLegacyNetworkInitializerFunctionReferencesRemainUsable() {
    let makeResponse: (
        String?,
        Int?,
        String?,
        String?,
        [String: String],
        Network.Source?,
        [String: String]?,
        Int?
    ) -> Network.Response = Network.Response.init
    let response = makeResponse(nil, 204, nil, nil, [:], nil, nil, nil)

    let makeMetrics: (
        Double?,
        String?,
        String?,
        Int?,
        Int?
    ) -> Network.Metrics = Network.Metrics.init
    let metrics = makeMetrics(42, "h2", "203.0.113.10:443", 128, 256)

    #expect(response.status == 204)
    #expect(response.security == nil)
    #expect(metrics.networkProtocol == "h2")
    #expect(metrics.securityConnection == nil)
}

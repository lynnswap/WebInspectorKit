import Foundation
import Testing
import WebInspectorDataKit
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
func webInspectorProxyMetricsRequestHeadersPreserveInitializerAndCopyContracts() {
    let makeMetrics = Network.Metrics.init
    let base = makeMetrics(42, "h2", "203.0.113.10:443", 128, 256)
    let securityConnection = Network.Security.Connection(tlsProtocol: "TLS 1.3")
    let reported = base
        .reporting(securityConnection: securityConnection)
        .reporting(requestHeaders: ["Cookie": "session=abc"])
    let replacedConnection = reported.reporting(
        securityConnection: Network.Security.Connection(cipher: "AES_128_GCM_SHA256")
    )

    #expect(base.requestHeaders == nil)
    #expect(base.securityConnection == nil)
    #expect(reported.timestamp == 42)
    #expect(reported.networkProtocol == "h2")
    #expect(reported.remoteAddress == "203.0.113.10:443")
    #expect(reported.encodedDataLength == 128)
    #expect(reported.decodedBodyLength == 256)
    #expect(reported.requestHeaders == ["Cookie": "session=abc"])
    #expect(reported.securityConnection == securityConnection)
    #expect(replacedConnection.requestHeaders == ["Cookie": "session=abc"])
    #expect(replacedConnection.securityConnection?.cipher == "AES_128_GCM_SHA256")
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
    let response = Network.Response(
        url: "https://example.com/",
        status: 200,
        statusText: "OK",
        mimeType: "text/html",
        headers: ["Content-Type": "text/html"],
        source: Network.Source(rawValue: "network"),
        requestHeaders: ["Accept": "text/html"],
        bodySize: 512
    )
        .reporting(security: security)
    let metrics = Network.Metrics(
        timestamp: 42,
        networkProtocol: "h2",
        remoteAddress: "203.0.113.10:443",
        encodedDataLength: 256,
        decodedBodyLength: 512
    )
        .reporting(
            securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
        )
    let snapshot = NetworkResponseSnapshot(
        url: "https://example.com/",
        status: 200,
        statusText: "OK",
        mimeType: "text/html",
        headers: ["Content-Type": "text/html"],
        source: "network",
        requestHeaders: ["Accept": "text/html"]
    )
        .reporting(security: security)

    #expect(response.security?.connection?.tlsProtocol == "TLS 1.3")
    #expect(response.security?.connection?.cipher == "AES_128_GCM_SHA256")
    #expect(response.security?.certificate?.subject == "example.com")
    #expect(response.security?.certificate?.validFrom == validFrom)
    #expect(response.security?.certificate?.validUntil == validUntil)
    #expect(response.security?.certificate?.dnsNames == ["example.com"])
    #expect(response.security?.certificate?.ipAddresses == [])
    #expect(response.status == 200)
    #expect(response.url == "https://example.com/")
    #expect(response.statusText == "OK")
    #expect(response.mimeType == "text/html")
    #expect(response.headers == ["Content-Type": "text/html"])
    #expect(response.source == Network.Source(rawValue: "network"))
    #expect(response.requestHeaders == ["Accept": "text/html"])
    #expect(response.bodySize == 512)
    #expect(metrics.securityConnection?.tlsProtocol == "TLS 1.3")
    #expect(metrics.timestamp == 42)
    #expect(metrics.networkProtocol == "h2")
    #expect(metrics.remoteAddress == "203.0.113.10:443")
    #expect(metrics.encodedDataLength == 256)
    #expect(metrics.decodedBodyLength == 512)
    #expect(snapshot.status == 200)
    #expect(snapshot.url == "https://example.com/")
    #expect(snapshot.statusText == "OK")
    #expect(snapshot.mimeType == "text/html")
    #expect(snapshot.headers == ["Content-Type": "text/html"])
    #expect(snapshot.source == "network")
    #expect(snapshot.requestHeaders == ["Accept": "text/html"])
    #expect(snapshot.security == security)
}

@Test
func webInspectorProxyLegacyNetworkInitializerFunctionReferencesRemainUsable() {
    let makeResponse = Network.Response.init
    let response = makeResponse(nil, 204, nil, nil, [:], nil, nil, nil)

    let makeMetrics = Network.Metrics.init
    let metrics = makeMetrics(42, "h2", "203.0.113.10:443", 128, 256)

    #expect(response.status == 204)
    #expect(response.security == nil)
    #expect(metrics.networkProtocol == "h2")
    #expect(metrics.requestHeaders == nil)
    #expect(metrics.securityConnection == nil)
}

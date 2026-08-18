import Foundation
import Observation
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func networkSecuritySummaryParsesOnlyStrictRawASCIISchemes() {
    let cases: [(url: String, expected: NetworkSecuritySummary)] = [
        ("http://example.test", .plaintextScheme(.http)),
        ("HTTP://example.test", .plaintextScheme(.http)),
        ("ws://example.test/socket", .plaintextScheme(.ws)),
        ("Ws://example.test/socket", .plaintextScheme(.ws)),
        ("https://example.test", .pending(.https)),
        ("WSS://example.test/socket", .pending(.wss)),
        ("git+ssh://example.test/repository", .notApplicable(scheme: "git+ssh")),
        ("CuStOm.1-2:value", .notApplicable(scheme: "CuStOm.1-2")),
        (" https://example.test", .notApplicable(scheme: nil)),
        ("1https://example.test", .notApplicable(scheme: nil)),
        ("ht_tps://example.test", .notApplicable(scheme: nil)),
        ("https：//example.test", .notApplicable(scheme: nil)),
        ("éxample:value", .notApplicable(scheme: nil)),
        ("relative/path", .notApplicable(scheme: nil)),
        ("", .notApplicable(scheme: nil)),
    ]

    for (index, testCase) in cases.enumerated() {
        let request = makeSecurityRequest(id: "scheme-\(index)", url: testCase.url)
        #expect(request.securitySummary == testCase.expected)
    }
}

@MainActor
@Test
func networkSecuritySummaryUsesResponseURLWithoutFallingBackOrOverridingSchemeFacts() {
    let reportedSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
    )
    let redirectedToPlaintext = makeSecurityRequest(
        id: "response-url-plaintext",
        url: "https://origin.example.test"
    )
    redirectedToPlaintext.applyResponse(
        Network.Response(url: "HTTP://final.example.test").reporting(security: reportedSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    redirectedToPlaintext.fail(errorText: "ignored", canceled: true, timestamp: 3)
    #expect(redirectedToPlaintext.securitySummary == .plaintextScheme(.http))

    let malformedResponseURL = makeSecurityRequest(
        id: "response-url-malformed",
        url: "https://origin.example.test"
    )
    malformedResponseURL.applyResponse(
        Network.Response(url: " https://final.example.test").reporting(security: reportedSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    #expect(malformedResponseURL.securitySummary == .notApplicable(scheme: nil))

    let emptyResponseURL = makeSecurityRequest(
        id: "response-url-empty",
        url: "https://origin.example.test"
    )
    emptyResponseURL.applyResponse(
        Network.Response(url: "", status: 200).reporting(security: reportedSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    #expect(emptyResponseURL.securitySummary == .notApplicable(scheme: nil))

    let otherResponseURL = makeSecurityRequest(
        id: "response-url-other",
        url: "https://origin.example.test"
    )
    otherResponseURL.applyResponse(
        Network.Response(url: "Custom+Protocol:value").reporting(security: reportedSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    #expect(otherResponseURL.securitySummary == .notApplicable(scheme: "Custom+Protocol"))
}

@MainActor
@Test
func networkSecuritySummaryDistinguishesEncryptedLifecycleStates() {
    let pending = makeSecurityRequest(id: "pending", url: "https://example.test/pending")
    #expect(pending.securitySummary == .pending(.https))

    let respondedWithoutMetadata = makeSecurityRequest(
        id: "responded-without-metadata",
        url: "https://example.test/responded-without-metadata"
    )
    respondedWithoutMetadata.applyDataReceived(dataLength: 1, encodedDataLength: 1, timestamp: 2)
    #expect(respondedWithoutMetadata.state == .responded)
    #expect(respondedWithoutMetadata.hasResponse == false)
    #expect(respondedWithoutMetadata.securitySummary == .pending(.https))

    let failed = makeSecurityRequest(id: "failed", url: "https://example.test/failed")
    failed.fail(errorText: "  transport failed  ", canceled: false, timestamp: 2)
    #expect(
        failed.securitySummary
            == .unavailable(
                .https,
                reason: .failedBeforeResponse(reason: "  transport failed  ")
            )
    )

    let canceled = makeSecurityRequest(id: "canceled", url: "wss://example.test/canceled")
    canceled.fail(errorText: "", canceled: true, timestamp: 2)
    #expect(
        canceled.securitySummary
            == .unavailable(
                .wss,
                reason: .canceledBeforeResponse(reason: "")
            )
    )

    let finished = makeSecurityRequest(id: "finished", url: "https://example.test/finished")
    finished.finish(timestamp: 2, sourceMapURL: nil, metrics: nil)
    #expect(
        finished.securitySummary
            == .unavailable(
                .https,
                reason: .completedWithoutResponse
            )
    )

    let responseWithoutSecurity = makeSecurityRequest(
        id: "response-without-security",
        url: "https://example.test/response-without-security"
    )
    responseWithoutSecurity.applyResponse(
        Network.Response(status: 204),
        resourceType: .fetch,
        timestamp: 2
    )
    #expect(
        responseWithoutSecurity.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .notReported
            )
    )
    responseWithoutSecurity.fail(errorText: "after response", canceled: true, timestamp: 3)
    #expect(
        responseWithoutSecurity.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .notReported
            )
    )

    let finishedAfterResponse = makeSecurityRequest(
        id: "finished-after-response",
        url: "https://example.test/finished-after-response"
    )
    finishedAfterResponse.applyResponse(
        Network.Response(status: 200),
        resourceType: .fetch,
        timestamp: 2
    )
    finishedAfterResponse.finish(timestamp: 3, sourceMapURL: nil, metrics: nil)
    #expect(
        finishedAfterResponse.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .notReported
            )
    )

    let presentEmpty = makeSecurityRequest(
        id: "present-empty-security",
        url: "https://example.test/present-empty-security"
    )
    let emptySecurity = Network.Security()
    presentEmpty.applyResponse(
        Network.Response().reporting(security: emptySecurity),
        resourceType: .fetch,
        timestamp: nil
    )
    #expect(
        presentEmpty.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .reported(emptySecurity)
            )
    )

    let nestedEmpty = makeSecurityRequest(
        id: "nested-empty-security",
        url: "https://example.test/nested-empty-security"
    )
    let nestedEmptySecurity = Network.Security(
        connection: Network.Security.Connection(),
        certificate: Network.Security.Certificate()
    )
    nestedEmpty.applyResponse(
        Network.Response().reporting(security: nestedEmptySecurity),
        resourceType: .fetch,
        timestamp: nil
    )
    #expect(
        nestedEmpty.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .reported(nestedEmptySecurity)
            )
    )

    let metricsOnly = makeSecurityRequest(
        id: "metrics-only-security",
        url: "https://example.test/metrics-only-security"
    )
    let emptyConnection = Network.Security.Connection()
    metricsOnly.finish(
        timestamp: 2,
        sourceMapURL: nil,
        metrics: Network.Metrics().reporting(securityConnection: emptyConnection)
    )
    let metricsOnlySecurity = Network.Security(connection: emptyConnection)
    #expect(
        metricsOnly.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .reported(metricsOnlySecurity)
            )
    )
}

@MainActor
@Test
func networkSecuritySummaryPreservesReportedMetadataExactly() throws {
    let validFrom = Date(timeIntervalSince1970: 9.75)
    let validUntil = Date(timeIntervalSince1970: -2.125)
    let security = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "", cipher: ""),
        certificate: Network.Security.Certificate(
            subject: "",
            validFrom: validFrom,
            validUntil: validUntil,
            dnsNames: ["z.example", "", "z.example", "a.example"],
            ipAddresses: ["", "127.0.0.1", "127.0.0.1"]
        )
    )
    let request = makeSecurityRequest(id: "lossless-security", url: "https://example.test")
    request.applyResponse(
        Network.Response(status: 200).reporting(security: security),
        resourceType: .fetch,
        timestamp: 2
    )

    guard case let .encryptedScheme(.https, metadata: .reported(projected)) = request.securitySummary else {
        Issue.record("Expected reported HTTPS security metadata.")
        return
    }
    #expect(projected == security)
    #expect(projected.connection?.tlsProtocol == "")
    #expect(projected.connection?.cipher == "")
    #expect(projected.certificate?.subject == "")
    #expect(projected.certificate?.validFrom == validFrom)
    #expect(projected.certificate?.validUntil == validUntil)
    #expect(projected.certificate?.dnsNames == ["z.example", "", "z.example", "a.example"])
    #expect(projected.certificate?.ipAddresses == ["", "127.0.0.1", "127.0.0.1"])

    let nilCollectionsSecurity = Network.Security(
        certificate: Network.Security.Certificate(dnsNames: nil, ipAddresses: nil)
    )
    let nilCollections = makeSecurityRequest(
        id: "nil-security-collections",
        url: "https://example.test/nil"
    )
    nilCollections.applyResponse(
        Network.Response(status: 200).reporting(security: nilCollectionsSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    guard
        case let .encryptedScheme(.https, metadata: .reported(projectedNilCollections)) =
            nilCollections.securitySummary
    else {
        Issue.record("Expected reported HTTPS security metadata with nil collections.")
        return
    }
    #expect(projectedNilCollections.certificate?.dnsNames == nil)
    #expect(projectedNilCollections.certificate?.ipAddresses == nil)

    let emptyCollectionsSecurity = Network.Security(
        certificate: Network.Security.Certificate(dnsNames: [], ipAddresses: [])
    )
    let emptyCollections = makeSecurityRequest(
        id: "empty-security-collections",
        url: "https://example.test/empty"
    )
    emptyCollections.applyResponse(
        Network.Response(status: 200).reporting(security: emptyCollectionsSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    guard
        case let .encryptedScheme(.https, metadata: .reported(projectedEmptyCollections)) =
            emptyCollections.securitySummary
    else {
        Issue.record("Expected reported HTTPS security metadata with empty collections.")
        return
    }
    #expect(projectedEmptyCollections.certificate?.dnsNames == [])
    #expect(projectedEmptyCollections.certificate?.ipAddresses == [])
}

@MainActor
@Test
func networkSecuritySummaryTracksRedirectReuseAndMemoryCacheLifecycles() {
    let id = Network.Request.ID("redirect-reuse-security-summary")
    let context = WebInspectorContext.preview(isolation: MainActor.shared)
    let responseSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "TLS 1.2")
    )
    let request = NetworkRequest(
        request: Network.Request(
            id: id,
            url: "https://example.test/start",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: 1,
        modelContext: context
    )
    request.applyResponse(
        Network.Response(status: 302).reporting(security: responseSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    #expect(
        request.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .reported(responseSecurity)
            )
    )

    request.applyRedirect(
        to: Network.Request(
            id: id,
            url: "wss://example.test/final",
            method: "GET"
        ),
        redirectResponse: Network.Response(status: 302).reporting(security: responseSecurity),
        timestamp: 3,
        resourceType: .webSocket
    )
    #expect(request.securitySummary == .pending(.wss))
    #expect(request.security == nil)
    #expect(request.redirects.map(\.response.security) == [responseSecurity])

    request.applyRequestWillBeSent(
        request: Network.Request(
            id: id,
            url: "HTTP://example.test/reused",
            method: "GET"
        ),
        initiator: nil,
        navigationVisit: nil,
        resourceType: .fetch,
        timestamp: 4,
        chronologySequence: 2
    )
    #expect(request.securitySummary == .plaintextScheme(.http))
    #expect(request.redirects.isEmpty)

    let cachedSecurity = Network.Security(
        certificate: Network.Security.Certificate(subject: "cached.example.test")
    )
    request.applyMemoryCache(
        response: Network.Response(
            url: "https://example.test/cached",
            status: 200
        ).reporting(security: cachedSecurity),
        initiator: Network.Initiator(kind: "other"),
        resourceType: .fetch,
        timestamp: 5
    )
    #expect(
        request.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .reported(cachedSecurity)
            )
    )

    request.applyMemoryCache(
        response: Network.Response(
            url: "https://example.test/cached-without-security",
            status: 200
        ),
        initiator: Network.Initiator(kind: "other"),
        resourceType: .fetch,
        timestamp: 6
    )
    #expect(
        request.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .notReported
            )
    )
}

@MainActor
@Test
func networkSecuritySummaryTracksWebSocketAndResponseMetricsMerging() throws {
    let plaintextWebSocket = makeSecurityRequest(
        id: "plaintext-websocket",
        url: "ws://example.test/socket",
        resourceType: .webSocket
    )
    let webSocketSecurity = Network.Security(
        connection: Network.Security.Connection(tlsProtocol: "unexpected")
    )
    plaintextWebSocket.applyWebSocketHandshakeResponse(
        Network.Response(status: 101).reporting(security: webSocketSecurity),
        timestamp: 2,
        chronologySequence: 2
    )
    #expect(plaintextWebSocket.securitySummary == .plaintextScheme(.ws))

    let encryptedWebSocket = makeSecurityRequest(
        id: "encrypted-websocket",
        url: "wss://example.test/socket",
        resourceType: .webSocket
    )
    #expect(encryptedWebSocket.securitySummary == .pending(.wss))
    encryptedWebSocket.applyWebSocketHandshakeResponse(
        Network.Response(status: 101).reporting(security: webSocketSecurity),
        timestamp: 2,
        chronologySequence: 2
    )
    #expect(
        encryptedWebSocket.securitySummary
            == .encryptedScheme(
                .wss,
                metadata: .reported(webSocketSecurity)
            )
    )

    let closedBeforeHandshake = makeSecurityRequest(
        id: "closed-before-handshake",
        url: "wss://example.test/closed",
        resourceType: .webSocket
    )
    closedBeforeHandshake.closeWebSocket(timestamp: 2, chronologySequence: 2)
    #expect(
        closedBeforeHandshake.securitySummary
            == .unavailable(
                .wss,
                reason: .completedWithoutResponse
            )
    )

    let responseCertificate = Network.Security.Certificate(
        subject: "example.test",
        dnsNames: ["example.test", "example.test"]
    )
    let responseSecurity = Network.Security(
        connection: Network.Security.Connection(
            tlsProtocol: "TLS 1.2",
            cipher: "response-cipher"
        ),
        certificate: responseCertificate
    )
    let merged = makeSecurityRequest(
        id: "response-metrics-merge",
        url: "https://example.test/merged"
    )
    merged.applyResponse(
        Network.Response(status: 200).reporting(security: responseSecurity),
        resourceType: .fetch,
        timestamp: 2
    )
    merged.finish(
        timestamp: 3,
        sourceMapURL: nil,
        metrics: Network.Metrics().reporting(
            securityConnection: Network.Security.Connection(tlsProtocol: "TLS 1.3")
        )
    )

    guard case let .encryptedScheme(.https, metadata: .reported(projected)) = merged.securitySummary
    else {
        Issue.record("Expected merged HTTPS security metadata.")
        return
    }
    #expect(projected.connection?.tlsProtocol == "TLS 1.3")
    #expect(projected.connection?.cipher == "response-cipher")
    #expect(projected.certificate == responseCertificate)
}

@MainActor
@Test
func networkSecuritySummaryParticipatesInNetworkRequestObservation() {
    let request = makeSecurityRequest(
        id: "observed-security-summary",
        url: "https://example.test/observed"
    )
    let delivered = Mutex(false)
    withObservationTracking {
        _ = request.securitySummary
    } onChange: {
        delivered.withLock { $0 = true }
    }

    request.applyResponse(
        Network.Response(status: 200),
        resourceType: .fetch,
        timestamp: 2
    )

    #expect(delivered.withLock { $0 })
    #expect(
        request.securitySummary
            == .encryptedScheme(
                .https,
                metadata: .notReported
            )
    )
}

@MainActor
private func makeSecurityRequest(
    id: String,
    url: String,
    resourceType: Network.ResourceType? = .fetch
) -> NetworkRequest {
    NetworkRequest(
        request: Network.Request(
            id: Network.Request.ID(id),
            url: url,
            method: "GET"
        ),
        initiator: nil,
        resourceType: resourceType,
        timestamp: 1,
        modelContext: WebInspectorContext.preview(isolation: MainActor.shared)
    )
}

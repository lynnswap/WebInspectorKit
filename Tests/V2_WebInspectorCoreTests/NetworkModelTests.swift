import Testing
@testable import V2_WebInspectorCore

@Test
func networkRequestIdentityIsScopedByTargetAndRequestID() async throws {
    let session = await NetworkSession()
    let requestID = NetworkRequestIdentifier("0.42")
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")

    let pageKey = await session.applyRequestWillBeSent(
        targetID: pageTargetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader-page",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/a"),
        timestamp: 1
    )
    let frameKey = await session.applyRequestWillBeSent(
        targetID: frameTargetID,
        requestID: requestID,
        frameID: .init("ad-frame"),
        loaderID: "loader-frame",
        documentURL: "https://ads.example",
        request: .init(url: "https://ads.example/a"),
        timestamp: 2
    )
    let snapshot = await session.snapshot()

    #expect(pageKey != frameKey)
    #expect(snapshot.orderedRequestIDs == [pageKey, frameKey])
    #expect(snapshot.requestsByID[pageKey]?.request.url == "https://example.com/a")
    #expect(snapshot.requestsByID[frameKey]?.request.url == "https://ads.example/a")
}

@Test
func networkRequestIdentityDoesNotIncludeRedirectIndex() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.43")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "http://example.com"),
        timestamp: 1
    )
    let redirectKey = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com"),
        redirectResponse: .init(url: "http://example.com", status: 302),
        timestamp: 2
    )
    let snapshot = await session.snapshot()

    #expect(redirectKey == key)
    #expect(snapshot.orderedRequestIDs == [key])
    #expect(snapshot.requestsByID[key]?.redirects.first?.id == .init(requestKey: key, redirectIndex: 0))
}

@Test
func requestKeepsEnvelopeTargetOriginatingTargetAndBackendResourceIdentitySeparate() async throws {
    let session = await NetworkSession()
    let pageProxyTargetID = ProtocolTargetIdentifier("page-proxy")
    let frameOriginTargetID = ProtocolTargetIdentifier("frame-ad")
    let requestID = NetworkRequestIdentifier("0.44")
    let backendResourceIdentifier = NetworkBackendResourceIdentifier(
        sourceProcessID: "web-content-2",
        resourceID: "resource-44"
    )

    let key = await session.applyRequestWillBeSent(
        targetID: pageProxyTargetID,
        requestID: requestID,
        frameID: .init("ad-frame"),
        loaderID: "loader-ad",
        documentURL: "https://ads.example",
        request: .init(url: "https://ads.example/ad.js"),
        originatingTargetID: frameOriginTargetID,
        backendResourceIdentifier: backendResourceIdentifier,
        timestamp: 1
    )
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.id == .init(targetID: pageProxyTargetID, requestID: requestID))
    #expect(request.originatingTargetID == frameOriginTargetID)
    #expect(request.backendResourceIdentifier == backendResourceIdentifier)
}

@Test
func backendResourceIdentifierPropagatesToLazyCommandIntents() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page-proxy")
    let requestID = NetworkRequestIdentifier("0.45")
    let backendResourceIdentifier = NetworkBackendResourceIdentifier(
        sourceProcessID: "web-content-3",
        resourceID: "resource-45"
    )

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/app.js"),
        backendResourceIdentifier: backendResourceIdentifier,
        timestamp: 1
    )
    await session.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        response: .init(url: "https://example.com/app.js", status: 200),
        timestamp: 2
    )
    let bodyIntent = await session.responseBodyCommandIntent(for: key)
    let certificateIntent = await session.serializedCertificateCommandIntent(for: key)

    #expect(bodyIntent == .getResponseBody(requestKey: key, backendResourceIdentifier: backendResourceIdentifier))
    #expect(certificateIntent == .getSerializedCertificate(requestKey: key, backendResourceIdentifier: backendResourceIdentifier))
}

@Test
@MainActor
func requestPostDataCreatesObservableRequestBody() throws {
    let session = NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.body")

    let key = session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(
            url: "https://example.com/form",
            method: "POST",
            headers: ["content-type": "application/x-www-form-urlencoded"],
            postData: "name=Jane+Doe&city=Tokyo%20East"
        ),
        timestamp: 1
    )
    let body = try #require(session.request(for: key)?.requestBody)

    #expect(body.fetchState == .loaded)
    #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
    #expect(body.textRepresentationSyntaxKind == .plainText)
}

@Test
@MainActor
func responseReceivedCreatesFetchableResponseBodyAndAppliesFetchedContent() throws {
    let session = NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.response-body")

    let key = session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/api/data.json"),
        timestamp: 1
    )
    session.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        response: .init(
            url: "https://example.com/api/data.json",
            status: 200,
            headers: ["content-type": "application/json"],
            mimeType: "application/json"
        ),
        timestamp: 2
    )
    let request = try #require(session.request(for: key))
    let body = try #require(request.responseBody)

    #expect(body.fetchState == .available)
    #expect(body.needsFetch)

    request.applyResponseBody(
        NetworkBodyPayload(
            body: #"{"name":"codex","value":42}"#,
            base64Encoded: false
        )
    )

    #expect(body.fetchState == .loaded)
    #expect(body.textRepresentation?.contains("\n") == true)
    #expect(body.textRepresentation?.contains(#""name""#) == true)
    #expect(body.textRepresentationSyntaxKind == .json)
}

@Test
func backendResourceIdentifierDoesNotChangeRequestGrouping() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page-proxy")
    let requestID = NetworkRequestIdentifier("0.46")
    let firstBackendIdentifier = NetworkBackendResourceIdentifier(sourceProcessID: "process-a", resourceID: "resource-a")
    let secondBackendIdentifier = NetworkBackendResourceIdentifier(sourceProcessID: "process-b", resourceID: "resource-b")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("frame-a"),
        loaderID: "loader-a",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/first"),
        backendResourceIdentifier: firstBackendIdentifier,
        timestamp: 1
    )
    let duplicateKey = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("frame-b"),
        loaderID: "loader-b",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/second"),
        backendResourceIdentifier: secondBackendIdentifier,
        timestamp: 2
    )
    let snapshot = await session.snapshot()

    #expect(duplicateKey == key)
    #expect(snapshot.orderedRequestIDs == [key])
    #expect(snapshot.requestsByID[key]?.backendResourceIdentifier == secondBackendIdentifier)
    #expect(snapshot.requestsByID[key]?.request.url == "https://example.com/first")
}

@Test
func redirectUpdatesSameRequestAndCreatesDerivedHopIdentity() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.99")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "http://example.com", method: "GET"),
        timestamp: 1
    )
    let redirectKey = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com", method: "GET"),
        redirectResponse: .init(url: "http://example.com", status: 301, statusText: "Moved Permanently"),
        timestamp: 2
    )
    let request = try #require(await session.requestSnapshot(for: key))
    let redirect = try #require(request.redirects.first)

    #expect(redirectKey == key)
    #expect(request.request.url == "https://example.com")
    #expect(request.redirects.count == 1)
    #expect(redirect.id == NetworkRedirectHopIdentifier(requestKey: key, redirectIndex: 0))
    #expect(redirect.request.url == "http://example.com")
    #expect(redirect.response.status == 301)
}

@Test
func redirectPreservesExistingMetadataWhenOptionalFieldsAreAbsent() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.101")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "http://example.com/script.js"),
        resourceType: .init("Script"),
        timestamp: 1
    )
    _ = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: nil,
        loaderID: nil,
        documentURL: nil,
        request: .init(url: "https://example.com/script.js"),
        redirectResponse: .init(url: "http://example.com/script.js", status: 301),
        timestamp: 2
    )
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.frameID == .init("main-frame"))
    #expect(request.loaderID == "loader")
    #expect(request.documentURL == "https://example.com")
    #expect(request.resourceType == .init("Script"))
    #expect(request.request.url == "https://example.com/script.js")
    #expect(request.redirects.count == 1)
}

@Test
func duplicateRequestWillBeSentWithoutRedirectKeepsExistingRequest() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.100")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/original"),
        timestamp: 1
    )
    let duplicateKey = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/duplicate"),
        timestamp: 2
    )
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(duplicateKey == key)
    #expect(request.request.url == "https://example.com/original")
    #expect(request.redirects.isEmpty)
}

@Test
func responseAndCompletionMutateRequestLifecycle() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.7")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/app.js"),
        resourceType: .init("Script"),
        timestamp: 1
    )
    await session.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        response: .init(url: "https://example.com/app.js", status: 200, mimeType: "text/javascript"),
        timestamp: 2
    )
    await session.applyDataReceived(targetID: targetID, requestID: requestID, dataLength: 10, encodedDataLength: 6, timestamp: 3)
    await session.applyLoadingFinished(targetID: targetID, requestID: requestID, timestamp: 4)
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.resourceType == .init("Script"))
    #expect(request.response?.status == 200)
    #expect(request.decodedDataLength == 10)
    #expect(request.encodedDataLength == 6)
    #expect(request.state == .finished)
}

@Test
func responseReceivedUpdatesResourceTypeFromProtocolEvent() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.71")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/photo.webp"),
        timestamp: 1
    )
    await session.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        resourceType: .image,
        response: .init(
            url: "https://example.com/photo.webp",
            status: 200,
            mimeType: "image/webp",
            requestHeaders: ["Accept": "image/webp"]
        ),
        timestamp: 2
    )
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.resourceType == .image)
    #expect(request.response?.mimeType == "image/webp")
    #expect(request.request.headers == ["Accept": "image/webp"])
}

@Test
func loadingFinishedPreservesSourceMapAndNetworkMetrics() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.72")

    let key = await session.applyRequestWillBeSent(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/app.js", headers: ["Accept": "*/*"]),
        resourceType: .script,
        timestamp: 1
    )
    await session.applyResponseReceived(
        targetID: targetID,
        requestID: requestID,
        response: .init(
            url: "https://example.com/app.js",
            status: 200,
            headers: ["Content-Type": "text/javascript"],
            mimeType: "text/javascript"
        ),
        timestamp: 2
    )
    await session.applyDataReceived(targetID: targetID, requestID: requestID, dataLength: 1, encodedDataLength: 1, timestamp: 3)
    await session.applyLoadingFinished(
        targetID: targetID,
        requestID: requestID,
        timestamp: 4,
        sourceMapURL: "app.js.map",
        metrics: .init(
            networkProtocol: "h2",
            priority: .high,
            connectionIdentifier: "connection-1",
            remoteAddress: "203.0.113.10",
            requestHeaders: ["User-Agent": "V2"],
            requestHeaderBytesSent: 64,
            requestBodyBytesSent: 0,
            responseHeaderBytesReceived: 128,
            responseBodyBytesReceived: 300,
            responseBodyDecodedSize: 512,
            securityConnection: .init(protocolName: "TLS 1.3", cipher: "TLS_AES_128_GCM_SHA256"),
            isProxyConnection: false
        )
    )
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.sourceMapURL == "app.js.map")
    #expect(request.metrics?.networkProtocol == "h2")
    #expect(request.metrics?.requestHeaderBytesSent == 64)
    #expect(request.metrics?.responseHeaderBytesReceived == 128)
    #expect(request.encodedDataLength == 300)
    #expect(request.decodedDataLength == 512)
    #expect(request.request.headers == ["User-Agent": "V2"])
    #expect(request.response?.security?.connection?.protocolName == "TLS 1.3")
    #expect(request.state == .finished)
}

@Test
func memoryCacheEventCreatesFinishedCachedRequest() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("0.73")

    let key = await session.applyRequestServedFromMemoryCache(
        targetID: targetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader",
        documentURL: "https://example.com",
        timestamp: 5,
        initiator: .init(type: .parser, url: "https://example.com", lineNumber: 10),
        resource: .init(
            url: "https://example.com/cached.css",
            type: .styleSheet,
            response: .init(url: "https://example.com/cached.css", status: 200, mimeType: "text/css"),
            bodySize: 42,
            sourceMapURL: "cached.css.map"
        )
    )
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.resourceType == .styleSheet)
    #expect(request.response?.source == .memoryCache)
    #expect(request.cachedResourceBodySize == 42)
    #expect(request.decodedDataLength == 42)
    #expect(request.encodedDataLength == 42)
    #expect(request.sourceMapURL == "cached.css.map")
    #expect(request.initiator?.type == .parser)
    #expect(request.state == .finished)
}

@Test
func webSocketLifecycleKeepsHandshakeAndFrameHistory() async throws {
    let session = await NetworkSession()
    let targetID = ProtocolTargetIdentifier("page")
    let requestID = NetworkRequestIdentifier("ws.1")

    let key = await session.applyWebSocketCreated(
        targetID: targetID,
        requestID: requestID,
        url: "wss://example.com/socket"
    )
    await session.applyWebSocketWillSendHandshakeRequest(
        targetID: targetID,
        requestID: requestID,
        timestamp: 1,
        walltime: 100,
        request: .init(headers: ["Upgrade": "websocket"])
    )
    await session.applyWebSocketHandshakeResponseReceived(
        targetID: targetID,
        requestID: requestID,
        timestamp: 2,
        response: .init(status: 101, statusText: "Switching Protocols", headers: ["Upgrade": "websocket"])
    )
    await session.applyWebSocketFrameSent(
        targetID: targetID,
        requestID: requestID,
        timestamp: 3,
        response: .init(opcode: 1, mask: true, payloadData: "hello", payloadLength: 5)
    )
    await session.applyWebSocketFrameReceived(
        targetID: targetID,
        requestID: requestID,
        timestamp: 4,
        response: .init(opcode: 1, mask: false, payloadData: "world", payloadLength: 5)
    )
    await session.applyWebSocketClosed(targetID: targetID, requestID: requestID, timestamp: 5)
    let request = try #require(await session.requestSnapshot(for: key))

    #expect(request.resourceType == .webSocket)
    #expect(request.webSocketHandshakeRequest?.headers["Upgrade"] == "websocket")
    #expect(request.webSocketHandshakeResponse?.status == 101)
    #expect(request.webSocketReadyState == .closed)
    #expect(request.webSocketFrames.count == 2)
    #expect(request.decodedDataLength == 10)
    #expect(request.state == .finished)
}

@Test
func loadingFailureOnlyUpdatesMatchingTargetScopedRequest() async throws {
    let session = await NetworkSession()
    let requestID = NetworkRequestIdentifier("0.8")
    let pageTargetID = ProtocolTargetIdentifier("page")
    let frameTargetID = ProtocolTargetIdentifier("frame")

    let pageKey = await session.applyRequestWillBeSent(
        targetID: pageTargetID,
        requestID: requestID,
        frameID: .init("main-frame"),
        loaderID: "loader-page",
        documentURL: "https://example.com",
        request: .init(url: "https://example.com/a"),
        timestamp: 1
    )
    let frameKey = await session.applyRequestWillBeSent(
        targetID: frameTargetID,
        requestID: requestID,
        frameID: .init("ad-frame"),
        loaderID: "loader-frame",
        documentURL: "https://ads.example",
        request: .init(url: "https://ads.example/a"),
        timestamp: 2
    )

    await session.applyLoadingFailed(targetID: frameTargetID, requestID: requestID, timestamp: 3, errorText: "cancelled", canceled: true)
    let page = try #require(await session.requestSnapshot(for: pageKey))
    let frame = try #require(await session.requestSnapshot(for: frameKey))

    #expect(page.state == .pending)
    #expect(frame.state == .failed(errorText: "cancelled", canceled: true))
}

import Testing
@testable import WebInspectorKit

@MainActor
struct WINetworkStoreTests {
    @Test
    func keepsEntriesScopedBySessionAndRequestId() throws {
        let store = WINetworkStore()

        let firstStart = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "session": "first",
                "requestId": 1,
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(firstStart)

        let secondStart = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "session": "second",
                "requestId": 1,
                "url": "https://example.com/api",
                "method": "POST"
            ])
        )
        store.applyEvent(secondStart)

        #expect(store.entries.count == 2)
        #expect(store.entry(forRequestID: 1, sessionID: "second")?.url == "https://example.com/api")
        #expect(store.entry(forRequestID: 1, sessionID: "first")?.url == "https://example.com")
    }

    @Test
    func resetClearsSessionsAndEntries() throws {
        let store = WINetworkStore()
        let payload = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "requestId": 1,
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(payload)

        #expect(store.entries.isEmpty == false)

        store.reset()

        #expect(store.entries.isEmpty)
    }

    @Test
    func parsesNumericRequestIdFromString() throws {
        let payload = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "session": "wi_session_123",
                "requestId": "42",
                "url": "https://example.com",
                "method": "GET"
            ])
        )

        #expect(payload.sessionID == "wi_session_123")
        #expect(payload.requestID == 42)
    }

    @Test
    func storesRequestAndResponseBodies() throws {
        let store = WINetworkStore()

        let start = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "start",
                "requestId": 10,
                "url": "https://example.com/api",
                "method": "POST",
                "requestBody": #"{"hello":"world"}"#,
                "requestBodyBase64": false,
                "requestBodyTruncated": false,
                "requestBodySize": 17
            ])
        )
        store.applyEvent(start)

        let finish = try #require(
            HTTPNetworkEvent(dictionary: [
                "type": "finish",
                "requestId": 10,
                "responseBody": "ok",
                "responseBodyBase64": false,
                "responseBodyTruncated": false,
                "responseBodySize": 2
            ])
        )
        store.applyEvent(finish)

        let entry = try #require(store.entry(forRequestID: 10, sessionID: nil))
        #expect(entry.requestBody == #"{"hello":"world"}"#)
        #expect(entry.requestBodyIsBase64 == false)
        #expect(entry.requestBodyBytesSent == 17)
        #expect(entry.responseBody == "ok")
        #expect(entry.responseBodyIsBase64 == false)
        #expect(entry.responseBodyTruncated == false)
    }

    @Test
    func websocketHandshakeAndErrorEventsAreApplied() throws {
        let store = WINetworkStore()
        let created = try #require(
            WSNetworkEvent(dictionary: [
                "type": "wsCreated",
                "requestId": 1,
                "url": "wss://example.com/socket",
                "startTime": 1_000.0,
                "wallTime": 2_000.0
            ])
        )
        store.applyWSEvent(created)

        let handshakeRequest = try #require(
            WSNetworkEvent(dictionary: [
                "type": "wsHandshakeRequest",
                "requestId": 1,
                "requestHeaders": ["sec-websocket-protocol": "chat"]
            ])
        )
        store.applyWSEvent(handshakeRequest)

        let frameError = try #require(
            WSNetworkEvent(dictionary: [
                "type": "wsFrameError",
                "requestId": 1,
                "error": "WebSocket error",
                "endTime": 2_000.0
            ])
        )
        store.applyWSEvent(frameError)

        let entry = try #require(store.entry(forRequestID: 1, sessionID: nil))
        #expect(entry.phase == .failed)
        #expect(entry.errorDescription == "WebSocket error")
        #expect(entry.requestHeaders["sec-websocket-protocol"] == "chat")
    }
}

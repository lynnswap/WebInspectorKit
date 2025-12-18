import Testing
@testable import WebInspectorKit

@MainActor
struct WINetworkStoreTests {
    @Test
    func keepsEntriesScopedBySessionAndRequestId() throws {
        let store = WINetworkStore()

        let firstStart = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ], sessionID: "first")
        store.applyEvent(firstStart)

        let secondStart = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com/api",
            "method": "POST",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_050.0, wallMs: 1_700_000_000_050.0)
        ], sessionID: "second")
        store.applyEvent(secondStart)

        #expect(store.entries.count == 2)
        #expect(store.entry(forRequestID: 1, sessionID: "second")?.url == "https://example.com/api")
        #expect(store.entry(forRequestID: 1, sessionID: "first")?.url == "https://example.com")
    }

    @Test
    func resetClearsSessionsAndEntries() throws {
        let store = WINetworkStore()
        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(payload)

        #expect(store.entries.isEmpty == false)

        store.reset()

        #expect(store.entries.isEmpty)
    }

    @Test
    func preservesRequestIdFromPayload() throws {
        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 42,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ], sessionID: "wi_session_123")

        #expect(payload.sessionID == "wi_session_123")
        #expect(payload.requestID == 42)
    }

    @Test
    func storesRequestAndResponseBodies() throws {
        let store = WINetworkStore()

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 10,
            "url": "https://example.com/api",
            "method": "POST",
            "body": [
                "kind": "text",
                "encoding": "utf-8",
                "preview": #"{"hello":"world"}"#,
                "truncated": false,
                "size": 17
            ],
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(start)

        let finish = try NetworkTestHelpers.decodeEvent([
            "kind": "loadingFinished",
            "requestId": 10,
            "body": [
                "kind": "text",
                "encoding": "utf-8",
                "preview": "ok",
                "truncated": false,
                "size": 2
            ],
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_200.0, wallMs: 1_700_000_000_200.0)
        ])
        store.applyEvent(finish)

        let entry = try #require(store.entry(forRequestID: 10, sessionID: nil))
        #expect(entry.requestBody?.displayText == #"{"hello":"world"}"#)
        #expect(entry.requestBody?.isBase64Encoded == false)
        #expect(entry.requestBody?.size == 17)
        #expect(entry.requestBodyBytesSent == 17)
        #expect(entry.responseBody?.displayText == "ok")
        #expect(entry.responseBody?.isBase64Encoded == false)
        #expect(entry.responseBody?.isTruncated == false)
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

    @Test
    func decodesNetworkEventBatchPayload() throws {
        let payload: [String: Any] = [
            "version": 1,
            "sessionId": "batch-session",
            "seq": 1,
            "events": [[
                "kind": "requestWillBeSent",
                "requestId": 9,
                "url": "https://example.com",
                "method": "GET",
                "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
            ]]
        ]

        let batch = try #require(NetworkEventBatch.decode(from: payload))

        #expect(batch.sessionID == "batch-session")
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.kind == .requestWillBeSent)
    }

    @Test
    func lenientDecodeDropsInvalidEvents() throws {
        let payload: [String: Any] = [
            "version": 1,
            "sessionId": "batch-session",
            "seq": 1,
            "events": [
                [
                    "kind": "requestWillBeSent",
                    "requestId": 11,
                    "url": "https://example.com/valid",
                    "method": "GET",
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_100.0, wallMs: 1_700_000_000_100.0)
                ],
                [
                    "kind": "responseReceived",
                    "requestId": "invalid",
                    "status": 200
                ]
            ]
        ]

        let batch = try #require(NetworkEventBatch.decode(from: payload))

        #expect(batch.events.count == 1)
        #expect(batch.events.first?.requestID == 11)
    }
}

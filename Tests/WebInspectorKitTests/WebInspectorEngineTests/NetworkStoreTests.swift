import Testing
@testable import WebInspectorEngine

@MainActor
struct NetworkStoreTests {
    @Test
    func keepsEntriesScopedBySessionAndRequestId() throws {
        let store = NetworkStore()

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
        let store = NetworkStore()
        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(payload)

        #expect(store.entries.isEmpty == false)

        store.clear()

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
        let store = NetworkStore()

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

        let entryCandidate = store.entry(forRequestID: 10, sessionID: nil)
        let entry = try #require(entryCandidate)
        #expect(entry.requestBody?.displayText == #"{"hello":"world"}"#)
        #expect(entry.requestBody?.isBase64Encoded == false)
        #expect(entry.requestBody?.size == 17)
        #expect(entry.requestBodyBytesSent == 17)
        #expect(entry.responseBody?.displayText == "ok")
        #expect(entry.responseBody?.isBase64Encoded == false)
        #expect(entry.responseBody?.isTruncated == false)
    }

    @Test
    func resourceTimingDefaultsMethodToGETWhenMissing() throws {
        let store = NetworkStore()
        let event = try NetworkTestHelpers.decodeEvent([
            "kind": "resourceTiming",
            "requestId": 500,
            "url": "https://example.com/asset.js",
            "startTime": NetworkTestHelpers.timePayload(monotonicMs: 5_000.0, wallMs: 1_700_000_005_000.0),
            "endTime": NetworkTestHelpers.timePayload(monotonicMs: 5_020.0, wallMs: 1_700_000_005_020.0)
        ], sessionID: "resource-session")

        store.applyEvent(event)

        let entry = try #require(store.entry(forRequestID: 500, sessionID: "resource-session"))
        #expect(entry.method == "GET")
    }

    @Test
    func websocketHandshakeAndErrorEventsAreApplied() throws {
        let store = NetworkStore()
        let createdCandidate = WSNetworkEvent(dictionary: [
                "type": "wsCreated",
                "requestId": 1,
                "url": "wss://example.com/socket",
                "startTime": 1_000.0,
                "wallTime": 2_000.0
            ])
        let created = try #require(createdCandidate)
        store.applyEvent(created)

        let handshakeRequestCandidate = WSNetworkEvent(dictionary: [
                "type": "wsHandshakeRequest",
                "requestId": 1,
                "requestHeaders": ["sec-websocket-protocol": "chat"]
            ])
        let handshakeRequest = try #require(handshakeRequestCandidate)
        store.applyEvent(handshakeRequest)

        let frameErrorCandidate = WSNetworkEvent(dictionary: [
                "type": "wsFrameError",
                "requestId": 1,
                "error": "WebSocket error",
                "endTime": 2_000.0
            ])
        let frameError = try #require(frameErrorCandidate)
        store.applyEvent(frameError)

        let entryCandidate = store.entry(forRequestID: 1, sessionID: nil)
        let entry = try #require(entryCandidate)
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

        let batchCandidate = NetworkEventBatch.decode(from: payload)
        let batch = try #require(batchCandidate)

        #expect(batch.sessionID == "batch-session")
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.kind == .requestWillBeSent)
    }

    @Test
    func decodesSchemaVersionAsBatchVersion() throws {
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "version": 1,
            "sessionId": "schema-session",
            "seq": 9,
            "events": [[
                "kind": "requestWillBeSent",
                "requestId": 91,
                "url": "https://example.com/schema",
                "method": "GET",
                "time": NetworkTestHelpers.timePayload(monotonicMs: 2_000.0, wallMs: 1_700_000_002_000.0)
            ]]
        ]

        let batchCandidate = NetworkEventBatch.decode(from: payload)
        let batch = try #require(batchCandidate)

        #expect(batch.version == 2)
        #expect(batch.sessionID == "schema-session")
        #expect(batch.events.first?.requestID == 91)
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
                ],
                [
                    "kind": "loadingFinished",
                    "requestId": true,
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_300.0, wallMs: 1_700_000_000_300.0)
                ]
            ]
        ]

        let batchCandidate = NetworkEventBatch.decode(from: payload)
        let batch = try #require(batchCandidate)

        #expect(batch.events.count == 1)
        #expect(batch.events.first?.requestID == 11)
    }

    @Test
    func batchedInsertionsRespectMaxEntriesEvenWhenBatchExceedsCap() throws {
        let store = NetworkStore()
        store.maxEntries = 3

        for requestID in 1...2 {
            let start = try NetworkTestHelpers.decodeEvent([
                "kind": "requestWillBeSent",
                "requestId": requestID,
                "url": "https://example.com/\(requestID)",
                "method": "GET",
                "time": NetworkTestHelpers.timePayload(
                    monotonicMs: 1_000.0 + Double(requestID),
                    wallMs: 1_700_000_000_000.0 + Double(requestID)
                )
            ], sessionID: "batch-session")
            store.applyEvent(start)
        }

        var events: [[String: Any]] = []
        events.reserveCapacity(8)
        for requestID in 3...10 {
            events.append([
                "kind": "resourceTiming",
                "requestId": requestID,
                "startTime": NetworkTestHelpers.timePayload(
                    monotonicMs: 2_000.0 + Double(requestID),
                    wallMs: 1_700_000_001_000.0 + Double(requestID)
                ),
                "endTime": NetworkTestHelpers.timePayload(
                    monotonicMs: 2_010.0 + Double(requestID),
                    wallMs: 1_700_000_001_010.0 + Double(requestID)
                )
            ])
        }

        let payload: [String: Any] = [
            "version": 1,
            "sessionId": "batch-session",
            "seq": 1,
            "events": events
        ]

        let batchCandidate = NetworkEventBatch.decode(from: payload)
        let batch = try #require(batchCandidate)

        store.applyBatchedInsertions(batch)

        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.requestID) == [8, 9, 10])
        #expect(store.entry(forRequestID: 1, sessionID: "batch-session") == nil)
        #expect(store.entry(forRequestID: 2, sessionID: "batch-session") == nil)
        #expect(store.entry(forRequestID: 8, sessionID: "batch-session")?.requestID == 8)
        #expect(store.entry(forRequestID: 9, sessionID: "batch-session")?.requestID == 9)
        #expect(store.entry(forRequestID: 10, sessionID: "batch-session")?.requestID == 10)

        for entry in store.entries {
            #expect(store.entry(forEntryID: entry.id) === entry)
        }
    }

    @Test
    func maxEntriesPrunesOldEntriesAndKeepsLookupConsistent() throws {
        let store = NetworkStore()
        store.maxEntries = 2

        let first = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com/one",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(first)
        let prunedEntryID = store.entries.first?.id

        let second = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 2,
            "url": "https://example.com/two",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_010.0, wallMs: 1_700_000_000_010.0)
        ])
        store.applyEvent(second)

        let third = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 3,
            "url": "https://example.com/three",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_020.0, wallMs: 1_700_000_000_020.0)
        ])
        store.applyEvent(third)

        #expect(store.entries.count == 2)
        #expect(store.entry(forRequestID: 1, sessionID: nil) == nil)
        #expect(store.entry(forRequestID: 2, sessionID: nil)?.requestID == 2)
        #expect(store.entry(forRequestID: 3, sessionID: nil)?.requestID == 3)

        let removedID = try #require(prunedEntryID)
        #expect(store.entry(forEntryID: removedID) == nil)

        for entry in store.entries {
            #expect(store.entry(forEntryID: entry.id) === entry)
        }
    }

    @Test
    func ignoresEventsWhenRecordingIsDisabled() throws {
        let store = NetworkStore()
        store.setRecording(false)

        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 404,
            "url": "https://example.com/disabled",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        store.applyEvent(payload)

        #expect(store.entries.isEmpty)
        #expect(store.entry(forRequestID: 404, sessionID: nil) == nil)
    }

    @Test
    func batchedInsertionsSkipExistingAndDuplicateRequestIDs() throws {
        let store = NetworkStore()
        let sessionID = "batch-session"

        let existing = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com/existing",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ], sessionID: sessionID)
        store.applyEvent(existing)

        let payload: [String: Any] = [
            "version": 1,
            "sessionId": sessionID,
            "seq": 1,
            "events": [
                [
                    "kind": "resourceTiming",
                    "requestId": 1,
                    "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_000.0, wallMs: 1_700_000_001_000.0),
                    "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_010.0, wallMs: 1_700_000_001_010.0)
                ],
                [
                    "kind": "resourceTiming",
                    "requestId": 2,
                    "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_020.0, wallMs: 1_700_000_001_020.0),
                    "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_030.0, wallMs: 1_700_000_001_030.0)
                ],
                [
                    "kind": "resourceTiming",
                    "requestId": 2,
                    "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_040.0, wallMs: 1_700_000_001_040.0),
                    "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_050.0, wallMs: 1_700_000_001_050.0)
                ]
            ]
        ]
        let batch = try NetworkTestHelpers.decodeBatch(payload)

        store.applyBatchedInsertions(batch)

        #expect(store.entries.map(\.requestID) == [1, 2])
        #expect(store.entry(forRequestID: 1, sessionID: sessionID)?.url == "https://example.com/existing")
        #expect(store.entry(forRequestID: 2, sessionID: sessionID)?.phase == .completed)
    }

    @Test
    func applyNetworkBatchProcessesMixedEventsAndBatchesResourceTiming() throws {
        let store = NetworkStore()
        let sessionID = "mixed-session"

        let payload: [String: Any] = [
            "version": 1,
            "sessionId": sessionID,
            "seq": 7,
            "events": [
                [
                    "kind": "requestWillBeSent",
                    "requestId": 1,
                    "url": "https://example.com/api",
                    "method": "GET",
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
                ],
                [
                    "kind": "responseReceived",
                    "requestId": 1,
                    "status": 200,
                    "statusText": "OK",
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_050.0, wallMs: 1_700_000_000_050.0)
                ],
                [
                    "kind": "loadingFinished",
                    "requestId": 1,
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_100.0, wallMs: 1_700_000_000_100.0)
                ],
                [
                    "kind": "resourceTiming",
                    "requestId": 2,
                    "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_000.0, wallMs: 1_700_000_001_000.0),
                    "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_010.0, wallMs: 1_700_000_001_010.0)
                ],
                [
                    "kind": "resourceTiming",
                    "requestId": 2,
                    "startTime": NetworkTestHelpers.timePayload(monotonicMs: 2_020.0, wallMs: 1_700_000_001_020.0),
                    "endTime": NetworkTestHelpers.timePayload(monotonicMs: 2_030.0, wallMs: 1_700_000_001_030.0)
                ]
            ]
        ]
        let batch = try NetworkTestHelpers.decodeBatch(payload)

        store.applyNetworkBatch(batch)

        #expect(store.entries.map(\.requestID) == [1, 2])
        #expect(store.entry(forRequestID: 1, sessionID: sessionID)?.phase == .completed)
        #expect(store.entry(forRequestID: 1, sessionID: sessionID)?.statusCode == 200)
        #expect(store.entry(forRequestID: 2, sessionID: sessionID)?.phase == .completed)
    }
}

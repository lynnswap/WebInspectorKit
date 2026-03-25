import Testing
import WebInspectorTestSupport
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
        Self.apply(firstStart, to: store, sessionID: "first")

        let secondStart = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com/api",
            "method": "POST",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_050.0, wallMs: 1_700_000_000_050.0)
        ], sessionID: "second")
        Self.apply(secondStart, to: store, sessionID: "second")

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
        Self.apply(payload, to: store)

        #expect(store.entries.isEmpty == false)

        store.clear()

        #expect(store.entries.isEmpty)
    }

    @Test
    func requestStartBumpsEntriesGeneration() throws {
        let store = NetworkStore()
        let initialGeneration = store.entriesGeneration

        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 12,
            "url": "https://example.com/callback",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        Self.apply(payload, to: store)

        #expect(store.entriesGeneration == initialGeneration + 1)
    }

    @Test
    func clearBumpsEntriesGeneration() throws {
        let store = NetworkStore()
        let payload = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 13,
            "url": "https://example.com/clear",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ])
        Self.apply(payload, to: store)
        let initialGeneration = store.entriesGeneration

        store.clear()

        #expect(store.entriesGeneration == initialGeneration + 1)
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

        #expect(payload.requestId == 42)
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
        Self.apply(start, to: store)

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
        Self.apply(finish, to: store)

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

        Self.apply(event, to: store, sessionID: "resource-session")

        let entry = try #require(store.entry(forRequestID: 500, sessionID: "resource-session"))
        #expect(entry.method == "GET")
    }

    @Test
    func websocketHandshakeAndErrorEventsAreApplied() throws {
        let store = NetworkStore()
        store.apply(
            .webSocketOpened(
                .init(
                    requestID: 1,
                    url: "wss://example.com/socket",
                    timestamp: 1,
                    wallTime: 2
                )
            ),
            sessionID: ""
        )
        store.apply(
            .webSocketHandshake(
                .init(
                    requestID: 1,
                    requestHeaders: NetworkHeaders(dictionary: ["sec-websocket-protocol": "chat"]),
                    statusCode: nil,
                    statusText: nil
                )
            ),
            sessionID: ""
        )
        store.apply(
            .webSocketClosed(
                .init(
                    requestID: 1,
                    timestamp: 2,
                    statusCode: nil,
                    statusText: nil,
                    closeCode: nil,
                    closeReason: nil,
                    closeWasClean: nil,
                    errorDescription: "WebSocket error",
                    failed: true
                )
            ),
            sessionID: ""
        )

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

        let batchCandidate = NetworkWire.PageHook.Batch.decode(from: payload)
        let batch = try #require(batchCandidate)

        #expect(batch.sessionID == "batch-session")
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.kindValue == .requestWillBeSent)
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

        let batchCandidate = NetworkWire.PageHook.Batch.decode(from: payload)
        let batch = try #require(batchCandidate)

        #expect(batch.version == 2)
        #expect(batch.sessionID == "schema-session")
        #expect(batch.events.first?.requestId == 91)
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

        let batchCandidate = NetworkWire.PageHook.Batch.decode(from: payload)
        let batch = try #require(batchCandidate)

        #expect(batch.events.count == 1)
        #expect(batch.events.first?.requestId == 11)
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
            Self.apply(start, to: store, sessionID: "batch-session")
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

        let batchCandidate = NetworkWire.PageHook.Batch.decode(from: payload)
        let batch = try #require(batchCandidate)
        let initialGeneration = store.entriesGeneration

        store.applyResourceTimingBatch(batch)

        #expect(store.entries.count == 3)
        #expect(store.entriesGeneration == initialGeneration + 1)
        #expect(store.entries.map(\.requestID) == [8, 9, 10])
        #expect(store.entry(forRequestID: 1, sessionID: "batch-session") == nil)
        #expect(store.entry(forRequestID: 2, sessionID: "batch-session") == nil)
        #expect(store.entry(forRequestID: 8, sessionID: "batch-session")?.requestID == 8)
        #expect(store.entry(forRequestID: 9, sessionID: "batch-session")?.requestID == 9)
        #expect(store.entry(forRequestID: 10, sessionID: "batch-session")?.requestID == 10)

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
        Self.apply(first, to: store)
        let second = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 2,
            "url": "https://example.com/two",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_010.0, wallMs: 1_700_000_000_010.0)
        ])
        Self.apply(second, to: store)

        let third = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 3,
            "url": "https://example.com/three",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_020.0, wallMs: 1_700_000_000_020.0)
        ])
        let initialGeneration = store.entriesGeneration
        Self.apply(third, to: store)

        #expect(store.entries.count == 2)
        #expect(store.entriesGeneration == initialGeneration + 1)
        #expect(store.entry(forRequestID: 1, sessionID: nil) == nil)
        #expect(store.entry(forRequestID: 2, sessionID: nil)?.requestID == 2)
        #expect(store.entry(forRequestID: 3, sessionID: nil)?.requestID == 3)

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
        Self.apply(payload, to: store)

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
        Self.apply(existing, to: store, sessionID: sessionID)

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

        store.applyResourceTimingBatch(batch)

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

    @Test
    func responseUpdateBumpsEntriesGenerationForExistingEntryDisplayStateChange() throws {
        let store = NetworkStore()
        let sessionID = "existing-entry-session"

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 1,
            "url": "https://example.com/existing",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ], sessionID: sessionID)
        Self.apply(start, to: store, sessionID: sessionID)
        let initialGeneration = store.entriesGeneration

        let response = try NetworkTestHelpers.decodeEvent([
            "kind": "responseReceived",
            "requestId": 1,
            "status": 200,
            "statusText": "OK",
            "mimeType": "application/json",
            "headers": ["content-type": "application/json"],
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_050.0, wallMs: 1_700_000_000_050.0)
        ], sessionID: sessionID)
        Self.apply(response, to: store, sessionID: sessionID)

        #expect(store.entriesGeneration == initialGeneration + 1)
    }

    @Test
    func networkBatchWithSingleAppendBumpsEntriesGenerationOnce() throws {
        let store = NetworkStore()
        let sessionID = "batch-generation-session"
        let initialGeneration = store.entriesGeneration

        let batch = try NetworkTestHelpers.decodeBatch([
            "version": 1,
            "sessionId": sessionID,
            "seq": 1,
            "events": [
                [
                    "kind": "requestWillBeSent",
                    "requestId": 1,
                    "url": "https://example.com/batch",
                    "method": "GET",
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
                ],
                [
                    "kind": "responseReceived",
                    "requestId": 1,
                    "status": 200,
                    "statusText": "OK",
                    "mimeType": "application/json",
                    "headers": ["content-type": "application/json"],
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_050.0, wallMs: 1_700_000_000_050.0)
                ],
                [
                    "kind": "loadingFinished",
                    "requestId": 1,
                    "time": NetworkTestHelpers.timePayload(monotonicMs: 1_100.0, wallMs: 1_700_000_000_100.0)
                ]
            ]
        ])

        store.applyNetworkBatch(batch)

        #expect(store.entriesGeneration == initialGeneration + 1)
    }

    @Test
    func requestStartMergesIntoExistingResourceTimingEntryAndBumpsEntriesGeneration() throws {
        let store = NetworkStore()
        let sessionID = "merge-session"

        let resourceTiming = try NetworkTestHelpers.decodeEvent([
            "kind": "resourceTiming",
            "requestId": 77,
            "url": "https://example.com/original",
            "startTime": NetworkTestHelpers.timePayload(monotonicMs: 7_700.0, wallMs: 1_700_000_007_700.0),
            "endTime": NetworkTestHelpers.timePayload(monotonicMs: 7_710.0, wallMs: 1_700_000_007_710.0)
        ], sessionID: sessionID)
        Self.apply(resourceTiming, to: store, sessionID: sessionID)
        let initialGeneration = store.entriesGeneration

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 77,
            "url": "https://example.com/redirected",
            "method": "POST",
            "headers": ["content-type": "application/json"],
            "body": [
                "kind": "text",
                "encoding": "utf-8",
                "preview": #"{"hello":"world"}"#,
                "truncated": false,
                "size": 17
            ],
            "time": NetworkTestHelpers.timePayload(monotonicMs: 7_705.0, wallMs: 1_700_000_007_705.0)
        ], sessionID: sessionID)
        Self.apply(start, to: store, sessionID: sessionID)

        #expect(store.entries.count == 1)
        let entry = try #require(store.entry(forRequestID: 77, sessionID: sessionID))
        #expect(entry.url == "https://example.com/redirected")
        #expect(entry.method == "POST")
        #expect(entry.requestHeaders["content-type"] == "application/json")
        #expect(entry.requestBody?.displayText == #"{"hello":"world"}"#)
        #expect(entry.phase == .pending)
        #expect(store.entriesGeneration == initialGeneration + 1)
    }

    @Test
    func resourceTimingCompletesExistingLiveEntryWithoutAppendingDuplicate() throws {
        let store = NetworkStore()
        let sessionID = "completion-session"

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 88,
            "url": "https://example.com/live",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 8_800.0, wallMs: 1_700_000_008_800.0)
        ], sessionID: sessionID)
        Self.apply(start, to: store, sessionID: sessionID)

        let resourceTiming = try NetworkTestHelpers.decodeEvent([
            "kind": "resourceTiming",
            "requestId": 88,
            "url": "https://example.com/live",
            "startTime": NetworkTestHelpers.timePayload(monotonicMs: 8_790.0, wallMs: 1_700_000_008_790.0),
            "endTime": NetworkTestHelpers.timePayload(monotonicMs: 8_820.0, wallMs: 1_700_000_008_820.0)
        ], sessionID: sessionID)
        Self.apply(resourceTiming, to: store, sessionID: sessionID)

        #expect(store.entries.count == 1)
        let entry = try #require(store.entry(forRequestID: 88, sessionID: sessionID))
        #expect(entry.phase == .completed)
        #expect(abs(entry.startTimestamp - 8.79) < 0.0001)
        #expect(abs((entry.endTimestamp ?? 0) - 8.82) < 0.0001)
    }

    @Test
    func batchedResourceTimingCompletesExistingLiveEntryWithoutAppendingDuplicate() throws {
        let store = NetworkStore()
        let sessionID = "batched-merge-session"

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 99,
            "url": "https://example.com/live",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 9_900.0, wallMs: 1_700_000_009_900.0)
        ], sessionID: sessionID)
        Self.apply(start, to: store, sessionID: sessionID)

        let batch = try NetworkTestHelpers.decodeBatch([
            "version": 1,
            "sessionId": sessionID,
            "seq": 3,
            "events": [[
                "kind": "resourceTiming",
                "requestId": 99,
                "url": "https://example.com/live",
                "startTime": NetworkTestHelpers.timePayload(monotonicMs: 9_890.0, wallMs: 1_700_000_009_890.0),
                "endTime": NetworkTestHelpers.timePayload(monotonicMs: 9_930.0, wallMs: 1_700_000_009_930.0)
            ]]
        ])
        store.applyNetworkBatch(batch)

        #expect(store.entries.count == 1)
        let entry = try #require(store.entry(forRequestID: 99, sessionID: sessionID))
        #expect(entry.phase == .completed)
        #expect(abs(entry.startTimestamp - 9.89) < 0.0001)
        #expect(abs((entry.endTimestamp ?? 0) - 9.93) < 0.0001)
    }
}

private extension NetworkStoreTests {
    static func apply(
        _ payload: NetworkWire.PageHook.Event,
        to store: NetworkStore,
        sessionID: String = ""
    ) {
        store.apply(payload, sessionID: sessionID)
    }
}

import Testing
import WebInspectorTestSupport
@testable import WebInspectorEngine

@MainActor
struct NetworkStoreTests {
    @Test
    func bodySyntaxKindUsesContentTypeAndURL() {
        #expect(
            NetworkEntry.bodySyntaxKind(
                contentType: "application/problem+json; charset=utf-8",
                url: "https://example.com/error"
            ) == .json
        )
        #expect(
            NetworkEntry.bodySyntaxKind(
                contentType: nil,
                url: "https://example.com/assets/app.mjs"
            ) == .javascript
        )
        #expect(
            NetworkEntry.bodySyntaxKind(
                contentType: "application/xhtml+xml",
                url: "https://example.com/page"
            ) == .html
        )
        #expect(
            NetworkEntry.bodySyntaxKind(
                contentType: "application/atom+xml",
                url: "https://example.com/feed"
            ) == .xml
        )
        #expect(NetworkEntry.isURLEncodedFormContentType("application/x-www-form-urlencoded; charset=UTF-8"))
    }

    @Test
    func networkBodyTextRepresentationUsesRawTextAndSummaryFallback() {
        let rawBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: "plain payload",
            summary: "summary"
        )
        #expect(rawBody.displayText == "plain payload")
        #expect(rawBody.textRepresentation == "plain payload")
        #expect(rawBody.textRepresentationSyntaxKind == .plainText)

        let summaryBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            summary: "No content"
        )
        #expect(summaryBody.displayText == "No content")
        #expect(summaryBody.textRepresentation == "No content")
    }

    @Test
    func networkBodyTextRepresentationDecodesBase64Text() {
        let body = NetworkBody(
            kind: .text,
            preview: "aGVsbG8gd29ybGQ=",
            full: nil,
            isBase64Encoded: true,
            isTruncated: false
        )

        #expect(body.displayText == "aGVsbG8gd29ybGQ=")
        #expect(body.textRepresentation == "hello world")
    }

    @Test
    func networkBodyTextRepresentationFormatsFormEntries() {
        let body = NetworkBody(
            kind: .form,
            preview: nil,
            full: nil,
            summary: "FormData",
            formEntries: [
                NetworkBody.FormEntry(name: "token", value: "abc", isFile: false, fileName: nil),
                NetworkBody.FormEntry(name: "upload", value: "", isFile: true, fileName: "payload.txt"),
            ]
        )

        #expect(body.textRepresentation == "token=abc\nupload=<file payload.txt>")
        #expect(body.textRepresentationSyntaxKind == .plainText)
    }

    @Test
    func networkBodyTextRepresentationFormatsURLEncodedRawBody() {
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: "name=Jane+Doe&city=Tokyo%20East"
        )

        body.applyTextRepresentationHints(
            syntaxKind: .plainText,
            treatsRawTextAsURLEncodedForm: true
        )

        #expect(body.treatsRawTextAsURLEncodedForm)
        #expect(body.textRepresentation == "name=Jane Doe\ncity=Tokyo East")
        #expect(body.textRepresentationSyntaxKind == .plainText)
    }

    @Test
    func networkBodyTextRepresentationPrettyPrintsJSON() {
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: #"{"name":"Ada","items":[1,2]}"#
        )

        #expect(body.textRepresentation?.contains("\n") == true)
        #expect(body.textRepresentation?.contains(#""name""#) == true)
        #expect(body.textRepresentationSyntaxKind == .json)
    }

    @Test
    func networkBodyTextRepresentationDoesNotDecodeBinaryBody() {
        let body = NetworkBody(
            kind: .binary,
            preview: "raw-bytes",
            full: "raw-bytes",
            summary: "Binary content"
        )

        #expect(body.displayText == "raw-bytes")
        #expect(body.textRepresentation == "Binary content")
        #expect(body.textRepresentationSyntaxKind == .plainText)
    }

    @Test
    func networkEntryConfiguresBodyRolesAndSyntaxHintsWhenBodiesAreAssigned() throws {
        let requestBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: #"{"ok":true}"#,
            role: .response
        )
        let responseBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: "body {}",
            role: .request
        )
        let store = NetworkStore()

        let entry = try #require(
            store.applySnapshots([
                Self.makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/styles/main.css",
                    requestHeaders: NetworkHeaders(dictionary: [
                        "content-type": "application/json",
                    ]),
                    responseMimeType: "text/css",
                    requestBody: requestBody,
                    responseBody: responseBody
                )
            ]).first
        )

        #expect(entry.requestBody === requestBody)
        #expect(requestBody.role == .request)
        #expect(requestBody.sourceSyntaxKind == .json)
        #expect(responseBody.role == .response)
        #expect(responseBody.sourceSyntaxKind == .css)
    }

    @Test
    func networkEntryRefreshesExistingBodySyntaxHintsWhenMetadataChanges() throws {
        let requestBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: "name=Jane+Doe"
        )
        let responseBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: "body {}"
        )
        let store = NetworkStore()
        let entry = try #require(
            store.applySnapshots([
                Self.makeSnapshot(
                    requestID: 2,
                    url: "https://example.com/body",
                    requestBody: requestBody,
                    responseBody: responseBody
                )
            ]).first
        )

        #expect(requestBody.sourceSyntaxKind == .plainText)
        #expect(requestBody.treatsRawTextAsURLEncodedForm == false)
        #expect(responseBody.sourceSyntaxKind == .plainText)

        entry.applyRequestStart(
            url: "https://example.com/app.js",
            method: nil,
            requestHeaders: NetworkHeaders(dictionary: [
                "content-type": "application/x-www-form-urlencoded",
            ]),
            requestType: nil,
            requestBody: nil,
            requestBodyBytesSent: nil,
            startTimestamp: 0,
            wallTime: nil
        )
        #expect(requestBody.treatsRawTextAsURLEncodedForm)
        #expect(requestBody.textRepresentation == "name=Jane Doe")
        #expect(responseBody.sourceSyntaxKind == .javascript)

        entry.applyResponse(
            statusCode: 200,
            statusText: "OK",
            mimeType: "text/css",
            responseHeaders: NetworkHeaders(),
            requestType: nil,
            timestamp: 1
        )
        #expect(responseBody.sourceSyntaxKind == .css)

        entry.applyResponse(
            statusCode: 200,
            statusText: "OK",
            mimeType: nil,
            responseHeaders: NetworkHeaders(dictionary: [
                "content-type": "application/json",
            ]),
            requestType: nil,
            timestamp: 2
        )
        #expect(responseBody.sourceSyntaxKind == .json)
    }

    @Test
    func networkEntryFetchedBodyUpdatesTextRepresentation() throws {
        let targetBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            isTruncated: true,
            reference: "response-ref",
            fetchState: .inline,
            role: .response
        )
        let fetchedBody = NetworkBody(
            kind: .text,
            preview: nil,
            full: #"{"updated":true}"#,
            isTruncated: false,
            reference: "response-ref",
            fetchState: .full,
            role: .response
        )
        let store = NetworkStore()
        let entry = try #require(
            store.applySnapshots([
                Self.makeSnapshot(
                    requestID: 3,
                    url: "https://example.com/fetch",
                    responseHeaders: NetworkHeaders(dictionary: [
                        "content-type": "application/json",
                    ]),
                    responseBody: targetBody
                )
            ]).first
        )

        entry.applyFetchedBody(fetchedBody, to: targetBody)

        #expect(targetBody.fetchState == .full)
        #expect(targetBody.textRepresentation?.contains("\n") == true)
        #expect(targetBody.textRepresentation?.contains(#""updated""#) == true)
        #expect(targetBody.textRepresentationSyntaxKind == .json)
    }

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
    func preservesRequestIdFromUpdate() throws {
        let update = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 42,
            "url": "https://example.com",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ], sessionID: "wi_session_123")

        #expect(update.requestID == 42)
    }

    @Test
    func storesRequestAndResponseBodies() throws {
        let store = NetworkStore()

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 10,
            "url": "https://example.com/api",
            "method": "POST",
            "headers": ["content-type": "application/json"],
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
        #expect(entry.requestBody?.role == .request)
        #expect(entry.requestBody?.sourceSyntaxKind == .json)
        #expect(entry.requestBodyBytesSent == 17)
        #expect(entry.responseBody?.displayText == "ok")
        #expect(entry.responseBody?.role == .response)
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
    func websocketFrameUpdateDoesNotBumpEntriesGeneration() {
        let store = NetworkStore()
        store.apply(
            .webSocketOpened(
                .init(
                    requestID: 2,
                    url: "wss://example.com/frames",
                    timestamp: 1,
                    wallTime: 2
                )
            ),
            sessionID: ""
        )
        let initialGeneration = store.entriesGeneration

        store.apply(
            .webSocketFrameAdded(
                .init(
                    requestID: 2,
                    frame: .init(
                        direction: .incoming,
                        opcode: 1,
                        payload: "hello",
                        payloadIsBase64: false,
                        payloadSize: 5,
                        payloadTruncated: false,
                        timestamp: 2
                    )
                )
            ),
            sessionID: ""
        )

        #expect(store.entriesGeneration == initialGeneration)
    }

    @Test
    func insertionsRespectMaxEntriesWhenUpdatesExceedCap() throws {
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

        for requestID in 3...10 {
            let event = try NetworkTestHelpers.decodeEvent([
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
            Self.apply(event, to: store, sessionID: "batch-session")
        }

        #expect(store.entries.count == 3)
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
    func resourceTimingUpdatesSkipDuplicateRequestIDs() throws {
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

        let resourceTimingPayloads: [[String: Any]] = [
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
        for payload in resourceTimingPayloads {
            let event = try NetworkTestHelpers.decodeEvent(payload)
            Self.apply(event, to: store, sessionID: sessionID)
        }

        #expect(store.entries.map(\.requestID) == [1, 2])
        #expect(store.entry(forRequestID: 1, sessionID: sessionID)?.url == "https://example.com/existing")
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
        let initialGeneration = store.entriesGeneration

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
        #expect(store.entriesGeneration == initialGeneration + 1)
    }

    @Test
    func completionUpdateBumpsEntriesGenerationForExistingEntrySortMetrics() throws {
        let store = NetworkStore()
        let sessionID = "completion-sort-session"

        let start = try NetworkTestHelpers.decodeEvent([
            "kind": "requestWillBeSent",
            "requestId": 123,
            "url": "https://example.com/completed",
            "method": "GET",
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_000.0, wallMs: 1_700_000_000_000.0)
        ], sessionID: sessionID)
        Self.apply(start, to: store, sessionID: sessionID)
        let initialGeneration = store.entriesGeneration

        let completed = try NetworkTestHelpers.decodeEvent([
            "kind": "loadingFinished",
            "requestId": 123,
            "encodedBodyLength": 512,
            "decodedBodySize": 1_024,
            "time": NetworkTestHelpers.timePayload(monotonicMs: 1_080.0, wallMs: 1_700_000_000_080.0)
        ], sessionID: sessionID)
        Self.apply(completed, to: store, sessionID: sessionID)

        let entry = try #require(store.entry(forRequestID: 123, sessionID: sessionID))
        #expect(entry.phase == .completed)
        #expect(entry.encodedBodyLength == 512)
        #expect(entry.decodedBodyLength == 1_024)
        #expect(store.entriesGeneration == initialGeneration + 1)
    }
}

private extension NetworkStoreTests {
    static func apply(
        _ update: NetworkEntry.Update,
        to store: NetworkStore,
        sessionID: String = ""
    ) {
        store.apply(update, sessionID: sessionID)
    }

    static func makeSnapshot(
        requestID: Int,
        url: String,
        method: String = "GET",
        requestHeaders: NetworkHeaders = NetworkHeaders(),
        responseMimeType: String? = nil,
        responseHeaders: NetworkHeaders = NetworkHeaders(),
        requestBody: NetworkBody? = nil,
        responseBody: NetworkBody? = nil
    ) -> NetworkEntry.Snapshot {
        NetworkEntry.Snapshot(
            sessionID: "test-session",
            requestID: requestID,
            request: NetworkEntry.Request(
                url: url,
                method: method,
                headers: requestHeaders,
                body: requestBody,
                bodyBytesSent: nil,
                type: nil,
                wallTime: nil
            ),
            response: NetworkEntry.Response(
                statusCode: 200,
                statusText: "OK",
                mimeType: responseMimeType,
                headers: responseHeaders,
                body: responseBody,
                blockedCookies: [],
                errorDescription: nil
            ),
            transfer: NetworkEntry.Transfer(
                startTimestamp: 0,
                endTimestamp: 1,
                duration: 1,
                encodedBodyLength: nil,
                decodedBodyLength: nil,
                phase: .completed
            )
        )
    }
}

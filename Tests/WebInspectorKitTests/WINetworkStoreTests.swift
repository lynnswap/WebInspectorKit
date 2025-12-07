import Testing
@testable import WebInspectorKit

@MainActor
struct WINetworkStoreTests {
    @Test
    func keepsEntriesScopedBySessionAndRequestId() throws {
        let store = WINetworkStore()

        let firstStart = try #require(
            WINetworkEventPayload(dictionary: [
                "type": "start",
                "session": "first",
                "requestId": 1,
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(firstStart)

        let secondStart = try #require(
            WINetworkEventPayload(dictionary: [
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
            WINetworkEventPayload(dictionary: [
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
            WINetworkEventPayload(dictionary: [
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
}

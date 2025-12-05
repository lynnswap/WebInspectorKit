import Testing
@testable import WebInspectorKit

@MainActor
struct WINetworkAgentModelTests {
    @Test
    func setRecordingUpdatesStoreFlag() {
        let agent = WINetworkAgentModel()

        #expect(agent.store.isRecording == true)
        agent.setRecording(false)
        #expect(agent.store.isRecording == false)
        agent.setRecording(true)
        #expect(agent.store.isRecording == true)
    }

    @Test
    func clearNetworkLogsResetsEntriesAndSelection() throws {
        let agent = WINetworkAgentModel()
        let store = agent.store

        let payload = try #require(
            WINetworkEventPayload(dictionary: [
                "type": "start",
                "id": "req_1",
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(payload)
        store.selectedEntryID = "req_1"
        #expect(store.entries.isEmpty == false)

        agent.clearNetworkLogs()

        #expect(store.entries.isEmpty)
        #expect(store.selectedEntryID == nil)
    }

    @Test
    func didClearPageWebViewResetsStore() throws {
        let agent = WINetworkAgentModel()
        let store = agent.store
        let payload = try #require(
            WINetworkEventPayload(dictionary: [
                "type": "start",
                "id": "req_2",
                "url": "https://example.com",
                "method": "GET"
            ])
        )
        store.applyEvent(payload)
        #expect(store.entries.count == 1)

        agent.didClearPageWebView()

        #expect(store.entries.isEmpty)
        #expect(store.selectedEntryID == nil)
    }
}

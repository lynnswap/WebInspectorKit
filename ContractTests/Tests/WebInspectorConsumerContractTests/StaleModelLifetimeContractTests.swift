import Testing
import WebInspectorDataKit

@MainActor
@Test
func collectionChangeStreamsFinishWhenInspectorIsReleasedFromConsumerPackage() async throws {
    var inspector: WebInspector? = WebInspector()
    var requestChanges = try #require(inspector?.network.requestChanges).makeAsyncIterator()
    var messageChanges = try #require(inspector?.console.messageChanges).makeAsyncIterator()
    weak let releasedInspector = inspector

    inspector = nil

    #expect(releasedInspector == nil)
    #expect(await requestChanges.next() == nil)
    #expect(await messageChanges.next() == nil)
}

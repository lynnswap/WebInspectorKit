import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
@Test
func collectionChangeStreamsFinishWhenContextIsReleasedFromConsumerPackage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    var container: WebInspectorContainer? = WebInspectorContainer(proxy: runtime.proxy)
    var context: WebInspectorContext? = WebInspectorContext(
        try #require(container)
    )
    var requestChanges = try #require(context?.network.requestChanges).makeAsyncIterator()
    var messageChanges = try #require(context?.console.messageChanges).makeAsyncIterator()
    weak let releasedContext = context

    context = nil
    container = nil

    #expect(releasedContext == nil)
    #expect(await requestChanges.next() == nil)
    #expect(await messageChanges.next() == nil)
    await runtime.proxy.close()
}

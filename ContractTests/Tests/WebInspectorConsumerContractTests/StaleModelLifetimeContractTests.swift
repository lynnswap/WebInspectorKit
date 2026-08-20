import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
@Test
func retainedFetchedResultsFinishStreamsAndReportStaleUpdatesFromConsumerPackage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    var container: WebInspectorContainer? = WebInspectorContainer(proxy: runtime.proxy)
    var context: WebInspectorContext? = WebInspectorContext(
        try #require(container),
        isolation: MainActor.shared
    )
    let results: WebInspectorFetchedResults<NetworkRequest> = try #require(context?.fetchedResults())
    let controller = WebInspectorFetchedResultsController(fetchedResults: results)
    var activeTransactions = controller.transactions.makeAsyncIterator()
    weak let releasedContext = context

    context = nil
    container = nil

    #expect(releasedContext == nil)
    #expect(await activeTransactions.next() == nil)
    var lateTransactions = controller.transactions.makeAsyncIterator()
    #expect(await lateTransactions.next() == nil)
    #expect(results.items.isEmpty)
    #expect(controller.snapshot.itemIDs.isEmpty)
    let error = WebInspectorProxyError.disconnected(
        "WebInspectorFetchedResults is not registered in this WebInspectorContext."
    )
    #expect(throws: error) {
        try results.updateFetchDescriptor(WebInspectorFetchDescriptor(fetchLimit: 1))
    }
    #expect(throws: error) {
        try controller.updateFetchDescriptor(WebInspectorFetchDescriptor(fetchLimit: 1))
    }
    await runtime.proxy.close()
}

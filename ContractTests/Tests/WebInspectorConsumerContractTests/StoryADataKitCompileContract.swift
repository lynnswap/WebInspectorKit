import Testing
import WebViewDataKit
import WebViewProxyKitTesting

@MainActor
@Test
func webViewDataKitPublicSurfaceIsUsableFromConsumerPackage() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let (_, container, context) = try await ContractTestSupport.startDataKitContext(runtime: runtime)

    let requestResults: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    let requestController: WebViewFetchedResultsController<NetworkRequest> =
        context.fetchedResultsController(for: .allRequests)
    let consoleResults: WebViewFetchedResults<ConsoleMessage> = context.fetchedResults(for: .allConsoleMessages)
    let consoleController: WebViewFetchedResultsController<ConsoleMessage> =
        context.fetchedResultsController(for: .allConsoleMessages)

    #expect(requestController.fetchedResults === requestResults)
    #expect(consoleController.fetchedResults === consoleResults)
    #expect(requestResults.items.isEmpty)
    #expect(consoleResults.items.isEmpty)
    #expect(context.state == .attached)

    let root = try #require(context.rootNode)
    #expect(root.nodeName == "#document")
    #expect(context.node(for: root.id) === root)

    context.select(root)
    #expect(context.selectedNode === root)
    context.select(nil)
    context.selectContext(nil)
    #expect(context.selectedNode == nil)
    #expect(context.selectedContext == nil)

    await ContractTestSupport.enqueueDataKitShutdownReplies(on: runtime.backend)
    await container.close()
    #expect(context.state == .detached)
    #expect(context.teardownError == nil)
}

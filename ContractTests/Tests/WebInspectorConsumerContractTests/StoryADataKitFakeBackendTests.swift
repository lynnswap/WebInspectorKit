import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func fakeBackendDrivesDataKitDOMNetworkAndRuntimeContracts() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let owner = ContractDataKitActor(runtime: runtime)
    try await owner.assertFakeBackendDrivesDOMNetworkAndRuntimeContracts()
    await owner.close()
}

@Test
func sharedContainerKeepsWireDomainsEnabledUntilLastContextStops() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let firstOwner = ContractDataKitActor(runtime: runtime, inspectorContainer: container)
    let secondOwner = ContractDataKitActor(runtime: runtime, inspectorContainer: container)

    let target = try await firstOwner.start()
    try await secondOwner.start(expectedSubscriberCount: 2)

    var commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0.domain == "Runtime" && $0.method == "enable" }.count == 1)
    #expect(commands.filter { $0.domain == "Network" && $0.method == "enable" }.count == 1)
    #expect(commands.filter { $0.domain == "Console" && $0.method == "enable" }.count == 1)

    await firstOwner.stopContext(enqueueShutdownReplies: false)

    commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Runtime", method: "disable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "disable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "Console", method: "disable")) == false)

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "log"),
            text: "second-context-still-live"
        )),
        target: target
    )
    try await secondOwner.waitForConsoleMessage(text: "second-context-still-live")

    await secondOwner.close()

    commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0.domain == "Runtime" && $0.method == "disable" }.count == 1)
    #expect(commands.filter { $0.domain == "Network" && $0.method == "disable" }.count == 1)
    #expect(commands.filter { $0.domain == "Console" && $0.method == "disable" }.count == 1)
}

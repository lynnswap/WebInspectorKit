import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func rawPeerDrivesDataKitDOMNetworkAndRuntimeContracts() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let owner = ContractDataKitActor(runtime: runtime)
    try await owner.assertRawPeerDrivesDOMNetworkAndRuntimeContracts()
    try await owner.close()
}

@Test
func sharedContainerKeepsWireDomainsEnabledUntilLastContextStops() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let firstOwner = ContractDataKitActor(runtime: runtime, inspectorContainer: container)
    let secondOwner = ContractDataKitActor(runtime: runtime, inspectorContainer: container)

    try await firstOwner.start()
    try await secondOwner.start(sharesDomainLeases: true)

    var commands = await firstOwner.observedCommands() + secondOwner.observedCommands()
    #expect(commands.filter { $0.method == "Runtime.enable" }.count == 1)
    #expect(commands.filter { $0.method == "Network.enable" }.count == 1)
    #expect(commands.filter { $0.method == "Console.enable" }.count == 1)

    try await firstOwner.stopContext(expectsDomainDisableCommands: false)

    commands = await firstOwner.observedCommands() + secondOwner.observedCommands()
    #expect(commands.contains { $0.method == "Runtime.disable" } == false)
    #expect(commands.contains { $0.method == "Network.disable" } == false)
    #expect(commands.contains { $0.method == "Console.disable" } == false)

    try await secondOwner.emitConsoleMessage(text: "second-context-still-live")
    try await secondOwner.waitForConsoleMessage(text: "second-context-still-live")

    try await secondOwner.close()

    commands = await firstOwner.observedCommands() + secondOwner.observedCommands()
    #expect(commands.filter { $0.method == "Runtime.disable" }.count == 1)
    #expect(commands.filter { $0.method == "Network.disable" }.count == 1)
    #expect(commands.filter { $0.method == "Console.disable" }.count == 1)
}

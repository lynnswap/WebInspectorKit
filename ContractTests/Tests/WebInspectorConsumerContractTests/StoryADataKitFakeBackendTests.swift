import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test
func fakeBackendDrivesDataKitDOMNetworkAndRuntimeContracts() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let owner = ContractDataKitActor(runtime: runtime)
    do {
        try await owner.assertFakeBackendDrivesDOMNetworkAndRuntimeContracts()
    } catch {
        await owner.close()
        throw error
    }
    await owner.close()
}

@Test
func sharedContainerKeepsWireDomainsEnabledUntilLastContextStops() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let container = WebInspectorContainer(proxy: runtime.proxy)
    let firstOwner = ContractDataKitActor(runtime: runtime, inspectorContainer: container)
    let secondOwner = ContractDataKitActor(runtime: runtime, inspectorContainer: container)

    let target: WebInspectorTarget
    do {
        target = try await firstOwner.start()
        try await secondOwner.start(requiresDomainEnableReplies: false)
    } catch {
        await firstOwner.close()
        await secondOwner.close()
        throw error
    }

    var commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0.domain == "Inspector" && $0.method == "enable" }.count == 1)
    #expect(commands.filter { $0.domain == "Inspector" && $0.method == "initialized" }.count == 1)
    #expect(commands.filter { $0.domain == "Page" && $0.method == "enable" }.count == 1)
    #expect(commands.filter { $0.domain == "Runtime" && $0.method == "enable" }.count == 1)
    #expect(commands.filter { $0.domain == "Network" && $0.method == "enable" }.count == 1)
    #expect(commands.filter { $0.domain == "Console" && $0.method == "enable" }.count == 1)

    await firstOwner.stopContext(enqueueShutdownReplies: false)

    commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Inspector", method: "disable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "Page", method: "disable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "Runtime", method: "disable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "Network", method: "disable")) == false)
    #expect(commands.contains(RecordedCommand(domain: "Console", method: "disable")) == false)

    var consoleTransactions = await secondOwner.consoleTransactions().makeAsyncIterator()
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "log"),
            text: "second-context-still-live"
        )),
        target: target
    )
    while await secondOwner.containsConsoleMessage(text: "second-context-still-live") == false {
        guard await consoleTransactions.next() != nil else {
            await secondOwner.close()
            throw ContractEventStreamEnded()
        }
    }

    await secondOwner.close()

    commands = await runtime.backend.recordedCommands()
    #expect(commands.filter { $0.domain == "Inspector" && $0.method == "disable" }.count == 1)
    #expect(commands.filter { $0.domain == "Page" && $0.method == "disable" }.count == 1)
    #expect(commands.filter { $0.domain == "Runtime" && $0.method == "disable" }.count == 1)
    #expect(commands.filter { $0.domain == "Network" && $0.method == "disable" }.count == 1)
    #expect(commands.filter { $0.domain == "Console" && $0.method == "disable" }.count == 1)
}

@Test
func dataKitStartupSurfacesPageEnableFailure() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let owner = ContractDataKitActor(runtime: runtime)
    let failure = WebInspectorProxyError.commandFailed(
        domain: "Page",
        method: "enable",
        message: "Page domain unavailable"
    )

    do {
        try await owner.start(pageEnableFailure: failure)
        Issue.record("Expected Page.enable to fail DataKit startup.")
    } catch {
        #expect(error as? WebInspectorProxyError == failure)
    }
    await owner.close()
}

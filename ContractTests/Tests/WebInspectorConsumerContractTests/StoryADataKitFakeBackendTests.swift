import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
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

@MainActor
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

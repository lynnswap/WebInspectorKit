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

import Testing
import WebInspectorDataKit
import WebInspectorProxyKitTesting

@Test
func webInspectorDataKitPublicSurfaceIsUsableFromConsumerPackage() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let owner = ContractDataKitActor(runtime: runtime)
    try await owner.start()
    try await owner.assertPublicSurfaceIsUsable()
    await owner.close()
}

import Testing
import WebKit
@testable import WebInspectorEngine

@MainActor
struct WIUserContentControllerStateRegistryTests {
    @Test
    func domScriptFlagIsStoredPerController() {
        let registry = WIUserContentControllerStateRegistry.shared
        let firstController = WKUserContentController()
        let secondController = WKUserContentController()

        registry.clearState(for: firstController)
        registry.clearState(for: secondController)

        #expect(registry.domBridgeScriptInstalled(on: firstController) == false)
        #expect(registry.domBridgeScriptInstalled(on: secondController) == false)

        registry.setDOMBridgeScriptInstalled(true, on: firstController)

        #expect(registry.domBridgeScriptInstalled(on: firstController) == true)
        #expect(registry.domBridgeScriptInstalled(on: secondController) == false)
    }

    @Test
    func networkTokenSignatureIsIsolatedPerController() {
        let registry = WIUserContentControllerStateRegistry.shared
        let firstController = WKUserContentController()
        let secondController = WKUserContentController()

        registry.clearState(for: firstController)
        registry.clearState(for: secondController)

        registry.setNetworkBridgeScriptInstalled(true, on: firstController)
        registry.setNetworkTokenBootstrapSignature("first-token", on: firstController)

        #expect(registry.networkBridgeScriptInstalled(on: firstController) == true)
        #expect(registry.networkTokenBootstrapSignature(on: firstController) == "first-token")

        #expect(registry.networkBridgeScriptInstalled(on: secondController) == false)
        #expect(registry.networkTokenBootstrapSignature(on: secondController) == nil)
    }
}

import WebKit

@MainActor
package enum WISPIContentWorldProvider {
    package static let worldName = "com.lynnswap.WebInspectorKit.bridge"

    package static func bridgeWorld(runtime: WISPIRuntime = .shared) -> WKContentWorld {
        runtime.makeBridgeWorld(named: worldName)
    }
}

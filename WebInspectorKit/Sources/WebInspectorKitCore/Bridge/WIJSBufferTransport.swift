import Foundation
import OSLog
import WebKit

private let jsBufferTransportLogger = Logger(subsystem: "WebInspectorKit", category: "JSBufferTransport")

@MainActor
package enum WIJSBufferTransport {
    package static let bufferThresholdBytes = 16 * 1024

    private static let publicAddSelector = NSSelectorFromString(WISPISymbols.publicAddBufferSelector)
    private static let privateAddSelector = NSSelectorFromString(WISPISymbols.privateAddBufferSelector)
    private static let publicRemoveSelector = NSSelectorFromString(WISPISymbols.publicRemoveBufferSelector)
    private static let privateRemoveSelector = NSSelectorFromString(WISPISymbols.privateRemoveBufferSelector)
    private static let bridgeClient: WISPIBridgeClient = WISPIObjCBridgeClient()

    package static func isAvailable(
        on controller: WKUserContentController,
        runtime: WISPIRuntime = .shared
    ) -> Bool {
        let capabilities = runtime.probeCapabilities(userContentController: controller)
        return capabilities.supportsPrivateFull
    }

    @discardableResult
    package static func addBuffer(
        data: Data,
        name: String,
        to controller: WKUserContentController,
        contentWorld: WKContentWorld,
        runtime: WISPIRuntime = .shared
    ) -> Bool {
        guard runtime.probeCapabilities(userContentController: controller).hasJSBufferClass else {
            jsBufferTransportLogger.error("selector_missing selector=buffer_class")
            return false
        }

        guard
            let buffer = bridgeClient.makeJSBuffer(
                data: data,
                classNames: [
                    WISPISymbols.publicJSScriptingBufferClass,
                    WISPISymbols.privateJSBufferClass,
                ],
                allocSelectorName: WISPISymbols.allocSelector,
                initSelectorName: WISPISymbols.initWithDataSelector
            )
        else {
            jsBufferTransportLogger.error("runtime_probe_failed: buffer init failed")
            return false
        }

        if controller.responds(to: publicAddSelector) {
            return bridgeClient.addBuffer(
                controller: controller,
                selectorName: WISPISymbols.publicAddBufferSelector,
                buffer: buffer,
                name: name,
                world: contentWorld,
                isPublicSignature: true
            )
        }

        if controller.responds(to: privateAddSelector) {
            return bridgeClient.addBuffer(
                controller: controller,
                selectorName: WISPISymbols.privateAddBufferSelector,
                buffer: buffer,
                name: name,
                world: contentWorld,
                isPublicSignature: false
            )
        }

        jsBufferTransportLogger.error("selector_missing selector=addBuffer")
        return false
    }

    package static func removeBuffer(
        named name: String,
        from controller: WKUserContentController,
        contentWorld: WKContentWorld
    ) {
        if controller.responds(to: publicRemoveSelector) {
            _ = bridgeClient.removeBuffer(
                controller: controller,
                selectorName: WISPISymbols.publicRemoveBufferSelector,
                name: name,
                world: contentWorld
            )
            return
        }

        if controller.responds(to: privateRemoveSelector) {
            _ = bridgeClient.removeBuffer(
                controller: controller,
                selectorName: WISPISymbols.privateRemoveBufferSelector,
                name: name,
                world: contentWorld
            )
            return
        }

        jsBufferTransportLogger.error("selector_missing selector=removeBuffer")
    }
}

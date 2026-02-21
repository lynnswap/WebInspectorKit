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

        guard let buffer = makeBufferObject(data: data) else {
            jsBufferTransportLogger.error("runtime_probe_failed: buffer init failed")
            return false
        }

        if controller.responds(to: publicAddSelector) {
            invokePublicAdd(
                controller: controller,
                selector: publicAddSelector,
                buffer: buffer,
                name: name,
                contentWorld: contentWorld
            )
            return true
        }

        if controller.responds(to: privateAddSelector) {
            invokePrivateAdd(
                controller: controller,
                selector: privateAddSelector,
                buffer: buffer,
                name: name,
                contentWorld: contentWorld
            )
            return true
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
            invokeRemove(
                controller: controller,
                selector: publicRemoveSelector,
                name: name,
                contentWorld: contentWorld
            )
            return
        }

        if controller.responds(to: privateRemoveSelector) {
            invokeRemove(
                controller: controller,
                selector: privateRemoveSelector,
                name: name,
                contentWorld: contentWorld
            )
            return
        }

        jsBufferTransportLogger.error("selector_missing selector=removeBuffer")
    }
}

private extension WIJSBufferTransport {
    static func makeBufferObject(data: Data) -> AnyObject? {
        let classNames = [WISPISymbols.publicJSScriptingBufferClass, WISPISymbols.privateJSBufferClass]
        let allocSelector = NSSelectorFromString(WISPISymbols.allocSelector)
        let initSelector = NSSelectorFromString(WISPISymbols.initWithDataSelector)

        for className in classNames {
            guard let bufferClass = NSClassFromString(className) as? NSObject.Type else {
                continue
            }
            guard bufferClass.instancesRespond(to: initSelector) else {
                continue
            }

            guard
                let allocated = (bufferClass as AnyObject)
                    .perform(allocSelector)?.takeUnretainedValue() as? NSObject
            else {
                continue
            }

            guard
                let initialized = allocated
                    .perform(initSelector, with: data as NSData)?.takeUnretainedValue()
            else {
                continue
            }

            return initialized as AnyObject
        }

        return nil
    }

    static func invokePublicAdd(
        controller: WKUserContentController,
        selector: Selector,
        buffer: AnyObject,
        name: String,
        contentWorld: WKContentWorld
    ) {
        typealias AddPublic = @convention(c) (AnyObject, Selector, AnyObject, NSString, WKContentWorld) -> Void
        let implementation = controller.method(for: selector)
        let function = unsafeBitCast(implementation, to: AddPublic.self)
        function(controller, selector, buffer, name as NSString, contentWorld)
    }

    static func invokePrivateAdd(
        controller: WKUserContentController,
        selector: Selector,
        buffer: AnyObject,
        name: String,
        contentWorld: WKContentWorld
    ) {
        typealias AddPrivate = @convention(c) (AnyObject, Selector, AnyObject, WKContentWorld, NSString) -> Void
        let implementation = controller.method(for: selector)
        let function = unsafeBitCast(implementation, to: AddPrivate.self)
        function(controller, selector, buffer, contentWorld, name as NSString)
    }

    static func invokeRemove(
        controller: WKUserContentController,
        selector: Selector,
        name: String,
        contentWorld: WKContentWorld
    ) {
        typealias Remove = @convention(c) (AnyObject, Selector, NSString, WKContentWorld) -> Void
        let implementation = controller.method(for: selector)
        let function = unsafeBitCast(implementation, to: Remove.self)
        function(controller, selector, name as NSString, contentWorld)
    }
}

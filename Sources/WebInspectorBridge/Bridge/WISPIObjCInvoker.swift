import Foundation

@MainActor
package enum WISPIObjCInvoker {
    private static let bridgeClient: WISPIBridgeClient = WISPIObjCBridgeClient()

    package static func objectResult(from target: NSObject, selector: Selector) -> NSObject? {
        bridgeClient.objectResult(target: target, selectorName: NSStringFromSelector(selector))
    }

    package static func boolResult(from target: NSObject, selector: Selector) -> Bool? {
        bridgeClient.boolResult(target: target, selectorName: NSStringFromSelector(selector))
    }
}

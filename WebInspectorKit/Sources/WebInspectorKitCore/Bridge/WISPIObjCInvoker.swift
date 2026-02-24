import Foundation

@MainActor
package enum WISPIObjCInvoker {
    package static func objectResult(from target: NSObject, selector: Selector) -> NSObject? {
        guard target.responds(to: selector) else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let implementation = target.method(for: selector)
        let function = unsafeBitCast(implementation, to: Getter.self)
        return function(target, selector) as? NSObject
    }

    package static func boolResult(from target: NSObject, selector: Selector) -> Bool? {
        guard target.responds(to: selector) else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = target.method(for: selector)
        let function = unsafeBitCast(implementation, to: Getter.self)
        return function(target, selector)
    }
}

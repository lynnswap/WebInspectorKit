#if canImport(UIKit)
import UIKit
import WebKit

enum WIWebViewViewportSPIBridge {
    static func apply(unobscuredSafeAreaInsets insets: UIEdgeInsets, to object: NSObject) {
        let selector = NSSelectorFromString("_setUnobscuredSafeAreaInsets:")
        guard object.responds(to: selector) else {
            return
        }

        typealias Setter = @convention(c) (NSObject, Selector, UIEdgeInsets) -> Void
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
        implementation(object, selector, insets)
    }

    static func apply(obscuredSafeAreaEdges edges: UIRectEdge, to object: NSObject) {
        let selector = NSSelectorFromString("_setObscuredInsetEdgesAffectedBySafeArea:")
        guard object.responds(to: selector) else {
            return
        }

        typealias Setter = @convention(c) (NSObject, Selector, UInt) -> Void
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
        implementation(object, selector, edges.rawValue)
    }

    static func inputViewBoundsInWindow(of object: NSObject) -> CGRect? {
        let selector = NSSelectorFromString("_inputViewBoundsInWindow")
        guard object.responds(to: selector) else {
            return nil
        }

        typealias Getter = @convention(c) (NSObject, Selector) -> CGRect
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Getter.self)
        return implementation(object, selector)
    }
}
#endif

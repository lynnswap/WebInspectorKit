#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorCore

enum WIWebViewViewportSPIBridge {
    private static let setUnobscuredSafeAreaInsetsSelector = NSSelectorFromString(
        WISPISymbols.setUnobscuredSafeAreaInsetsSelector
    )
    private static let setObscuredInsetEdgesAffectedBySafeAreaSelector = NSSelectorFromString(
        WISPISymbols.setObscuredInsetEdgesAffectedBySafeAreaSelector
    )
    private static let inputViewBoundsInWindowSelector = NSSelectorFromString(
        WISPISymbols.inputViewBoundsInWindowSelector
    )

    static func apply(unobscuredSafeAreaInsets insets: UIEdgeInsets, to object: NSObject) {
        let selector = Self.setUnobscuredSafeAreaInsetsSelector
        guard object.responds(to: selector) else {
            return
        }

        typealias Setter = @convention(c) (NSObject, Selector, UIEdgeInsets) -> Void
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
        implementation(object, selector, insets)
    }

    static func apply(obscuredSafeAreaEdges edges: UIRectEdge, to object: NSObject) {
        let selector = Self.setObscuredInsetEdgesAffectedBySafeAreaSelector
        guard object.responds(to: selector) else {
            return
        }

        typealias Setter = @convention(c) (NSObject, Selector, UInt) -> Void
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
        implementation(object, selector, edges.rawValue)
    }

    static func inputViewBoundsInWindow(of object: NSObject) -> CGRect? {
        let selector = Self.inputViewBoundsInWindowSelector
        guard object.responds(to: selector) else {
            return nil
        }

        typealias Getter = @convention(c) (NSObject, Selector) -> CGRect
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Getter.self)
        return implementation(object, selector)
    }
}
#endif

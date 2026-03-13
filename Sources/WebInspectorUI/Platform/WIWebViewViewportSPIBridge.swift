#if canImport(UIKit)
import UIKit
import WebKit
import WebInspectorCore
import WebInspectorSPIObjCShim

enum WIWebViewViewportSPIBridge {
    private static let setContentScrollInsetSelector = NSSelectorFromString(
        WISPISymbols.setContentScrollInsetSelector
    )
    private static let setContentScrollInsetInternalSelector = NSSelectorFromString(
        WISPISymbols.setContentScrollInsetInternalSelector
    )
    private static let setObscuredInsetsInternalSelector = NSSelectorFromString(
        WISPISymbols.setObscuredInsetsInternalSelector
    )
    private static let setUnobscuredSafeAreaInsetsSelector = NSSelectorFromString(
        WISPISymbols.setUnobscuredSafeAreaInsetsSelector
    )
    private static let setObscuredInsetEdgesAffectedBySafeAreaSelector = NSSelectorFromString(
        WISPISymbols.setObscuredInsetEdgesAffectedBySafeAreaSelector
    )
    private static let frameOrBoundsMayHaveChangedSelector = NSSelectorFromString(
        WISPISymbols.frameOrBoundsMayHaveChangedSelector
    )
    private static let inputViewBoundsInWindowSelector = NSSelectorFromString(
        WISPISymbols.inputViewBoundsInWindowSelector
    )

    @discardableResult
    static func applyObscuredInsetsFallback(
        _ resolvedMetrics: WIWebViewChromeResolvedMetrics,
        to object: NSObject
    ) -> Bool {
        guard object.responds(to: Self.setObscuredInsetsInternalSelector) else {
            return false
        }

        setObscuredInsetsInternal(resolvedMetrics.obscuredInsets, to: object)
        _ = WIKRuntimeBridge.setBoolValueOnTarget(
            object,
            key: WISPISymbols.automaticallyAdjustsViewLayoutSizesWithObscuredInsetKey,
            value: resolvedMetrics.obscuredInsets != .zero
        )
        apply(unobscuredSafeAreaInsets: resolvedMetrics.unobscuredSafeAreaInsets, to: object)
        apply(obscuredSafeAreaEdges: resolvedMetrics.safeAreaAffectedEdges, to: object)
        frameOrBoundsMayHaveChanged(on: object)
        return true
    }

    @discardableResult
    static func applyContentScrollInsetFallback(
        _ insets: UIEdgeInsets,
        to scrollView: NSObject,
        webView: NSObject
    ) -> Bool {
        guard applyContentScrollInset(insets, to: scrollView) else {
            return false
        }

        frameOrBoundsMayHaveChanged(on: webView)
        return true
    }

    private static func setObscuredInsetsInternal(_ insets: UIEdgeInsets, to object: NSObject) {
        let selector = Self.setObscuredInsetsInternalSelector
        typealias Setter = @convention(c) (NSObject, Selector, UIEdgeInsets) -> Void
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
        implementation(object, selector, insets)
    }

    private static func applyContentScrollInset(_ insets: UIEdgeInsets, to object: NSObject) -> Bool {
        if object.responds(to: Self.setContentScrollInsetSelector) {
            let selector = Self.setContentScrollInsetSelector
            typealias Setter = @convention(c) (NSObject, Selector, UIEdgeInsets) -> Void
            let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
            implementation(object, selector, insets)
            return true
        }

        guard object.responds(to: Self.setContentScrollInsetInternalSelector) else {
            return false
        }

        let selector = Self.setContentScrollInsetInternalSelector
        typealias Setter = @convention(c) (NSObject, Selector, UIEdgeInsets) -> Bool
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Setter.self)
        _ = implementation(object, selector, insets)
        return true
    }

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

    private static func frameOrBoundsMayHaveChanged(on object: NSObject) {
        let selector = Self.frameOrBoundsMayHaveChangedSelector
        guard object.responds(to: selector) else {
            return
        }

        typealias Method = @convention(c) (NSObject, Selector) -> Void
        let implementation = unsafe unsafeBitCast(object.method(for: selector), to: Method.self)
        implementation(object, selector)
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

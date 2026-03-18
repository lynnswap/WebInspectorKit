#if canImport(UIKit)
import UIKit
import WebKit

enum ViewportSPISelectorNames {
    private static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }

    static let setUnobscuredSafeAreaInsets = deobfuscate([":", "Insets", "Area", "Safe", "Unobscured", "set", "_"])
    static let setObscuredInsetEdgesAffectedBySafeArea = deobfuscate([
        ":", "Area", "Safe", "By", "Affected", "Edges", "Inset", "Obscured", "set", "_"
    ])
    static let setObscuredInsetsInternal = deobfuscate([":", "Internal", "Insets", "Obscured", "set", "_"])
    static let setContentScrollInset = deobfuscate([":", "Inset", "Scroll", "Content", "set", "_"])
    static let setContentScrollInsetInternal = deobfuscate([":", "Internal", "Inset", "Scroll", "Content", "set", "_"])
    static let frameOrBoundsMayHaveChanged = deobfuscate(["Changed", "Have", "May", "Bounds", "Or", "frame", "_"])
    static let inputViewBoundsInWindow = deobfuscate(["Window", "In", "Bounds", "View", "input", "_"])
}

enum ViewportSPIBridge {
    private static let setContentScrollInsetSelector = NSSelectorFromString(
        ViewportSPISelectorNames.setContentScrollInset
    )
    private static let setContentScrollInsetInternalSelector = NSSelectorFromString(
        ViewportSPISelectorNames.setContentScrollInsetInternal
    )
    private static let setObscuredInsetsInternalSelector = NSSelectorFromString(
        ViewportSPISelectorNames.setObscuredInsetsInternal
    )
    private static let setUnobscuredSafeAreaInsetsSelector = NSSelectorFromString(
        ViewportSPISelectorNames.setUnobscuredSafeAreaInsets
    )
    private static let setObscuredInsetEdgesAffectedBySafeAreaSelector = NSSelectorFromString(
        ViewportSPISelectorNames.setObscuredInsetEdgesAffectedBySafeArea
    )
    private static let frameOrBoundsMayHaveChangedSelector = NSSelectorFromString(
        ViewportSPISelectorNames.frameOrBoundsMayHaveChanged
    )
    private static let inputViewBoundsInWindowSelector = NSSelectorFromString(
        ViewportSPISelectorNames.inputViewBoundsInWindow
    )

    @discardableResult
    static func applyObscuredInsetsFallback(
        _ resolvedMetrics: ResolvedViewportMetrics,
        to object: NSObject
    ) -> Bool {
        guard object.responds(to: Self.setObscuredInsetsInternalSelector) else {
            return false
        }

        setObscuredInsetsInternal(resolvedMetrics.obscuredInsets, to: object)
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

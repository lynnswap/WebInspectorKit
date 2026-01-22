#if os(iOS)
import Foundation
import UIKit
import ObjectiveC.runtime

enum IMEUnderlineHook {
    private static var didSwizzleAttributed = false
    private static var didSwizzleMarked = false
    private static var underlineRGBA: UInt32 = 0
    private static let debugEnabled = true
    private static var didLogAttributedCall = false
    private static var didLogMarkedCall = false
    private static var didLogRewrite = false
    private static var didLogLayoutMismatch = false

    static func install() {
        guard !(didSwizzleAttributed && didSwizzleMarked) else {
            return
        }
        underlineRGBA = packedSRGB(UIColor.systemOrange)
        debugLog("install begin underlineRGBA=0x\(String(underlineRGBA, radix: 16))")
        if !didSwizzleAttributed {
            didSwizzleAttributed = swizzleSetAttributedMarkedText()
        }
        if !didSwizzleMarked {
            didSwizzleMarked = swizzleSetMarkedText()
        }
        debugLog("install done attributed=\(didSwizzleAttributed) marked=\(didSwizzleMarked)")
    }

    @discardableResult
    private static func swizzleSetAttributedMarkedText() -> Bool {
        guard let contentViewClass = NSClassFromString("WKContentView") else {
            debugLog("WKContentView not found for setAttributedMarkedText:selectedRange:")
            return false
        }
        let selector = NSSelectorFromString("setAttributedMarkedText:selectedRange:")
        guard let method = class_getInstanceMethod(contentViewClass, selector) else {
            debugLog("method setAttributedMarkedText:selectedRange: not found")
            return false
        }
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, NSAttributedString, NSRange) -> Void = { object, markedText, selectedRange in
            let patchedText = forceUnderlineAttributesIfNeeded(markedText)
            if debugEnabled && !didLogAttributedCall {
                didLogAttributedCall = true
                debugLog("setAttributedMarkedText:selectedRange: invoked patched=\(!markedText.isEqual(patchedText))")
            }
            typealias Function = @convention(c) (AnyObject, Selector, NSAttributedString, NSRange) -> Void
            let original = unsafeBitCast(originalIMP, to: Function.self)
            original(object, selector, patchedText, selectedRange)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
        debugLog("swizzled setAttributedMarkedText:selectedRange:")
        return true
    }

    @discardableResult
    private static func swizzleSetMarkedText() -> Bool {
        guard let contentViewClass = NSClassFromString("WKContentView") else {
            debugLog("WKContentView not found for _setMarkedText:underlines:highlights:selectedRange:")
            return false
        }
        let selector = NSSelectorFromString("_setMarkedText:underlines:highlights:selectedRange:")
        guard let method = class_getInstanceMethod(contentViewClass, selector) else {
            debugLog("method _setMarkedText:underlines:highlights:selectedRange: not found")
            return false
        }
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, NSString, UnsafeRawPointer, UnsafeRawPointer, NSRange) -> Void = { object, markedText, underlines, highlights, selectedRange in
            if debugEnabled && !didLogMarkedCall {
                didLogMarkedCall = true
                debugLog("_setMarkedText:underlines:highlights:selectedRange: invoked")
            }
            rewriteUnderlines(underlines)
            typealias Function = @convention(c) (AnyObject, Selector, NSString, UnsafeRawPointer, UnsafeRawPointer, NSRange) -> Void
            let original = unsafeBitCast(originalIMP, to: Function.self)
            original(object, selector, markedText, underlines, highlights, selectedRange)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
        debugLog("swizzled _setMarkedText:underlines:highlights:selectedRange:")
        return true
    }

    private static func forceUnderlineAttributesIfNeeded(_ text: NSAttributedString) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: text.length)
        var shouldForceUnderlines = false
        text.enumerateAttributes(in: fullRange, options: []) { attributes, _, stop in
            let hasUnderlineStyle = attributes[.underlineStyle] != nil
            let hasUnderlineColor = attributes[.underlineColor] != nil
            let hasBackgroundColor = attributes[.backgroundColor] != nil
            let hasForegroundColor = attributes[.foregroundColor] != nil

            if hasUnderlineStyle || hasUnderlineColor {
                shouldForceUnderlines = false
                stop.pointee = true
                return
            }
            if hasBackgroundColor || hasForegroundColor {
                shouldForceUnderlines = true
                stop.pointee = true
            }
        }

        guard shouldForceUnderlines else {
            return text
        }

        let mutable = NSMutableAttributedString(attributedString: text)
        mutable.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let hasBackgroundColor = attributes[.backgroundColor] != nil
            let hasForegroundColor = attributes[.foregroundColor] != nil
            guard hasBackgroundColor || hasForegroundColor else {
                return
            }
            let underlineStyle: Int
            if hasBackgroundColor {
                underlineStyle = NSUnderlineStyle.thick.rawValue
            } else {
                underlineStyle = NSUnderlineStyle.single.rawValue
            }
            mutable.removeAttribute(.backgroundColor, range: range)
            mutable.removeAttribute(.foregroundColor, range: range)
            mutable.addAttribute(.underlineStyle, value: underlineStyle, range: range)
        }
        return mutable
    }

    private static func rewriteUnderlines(_ underlines: UnsafeRawPointer) {
        guard VectorLayout.isExpectedLayout, CompositionUnderlineLayout.isExpectedLayout else {
            if debugEnabled && !didLogLayoutMismatch {
                didLogLayoutMismatch = true
                debugLog("layout mismatch vectorSize=\(MemoryLayout<VectorLayout>.size) underlineSize=\(MemoryLayout<CompositionUnderlineLayout>.size)")
            }
            return
        }

        let vector = underlines.assumingMemoryBound(to: VectorLayout.self).pointee
        guard vector.size > 0, vector.capacity >= vector.size else {
            return
        }
        guard vector.size < 1024 else {
            return
        }
        guard let buffer = vector.buffer else {
            return
        }

        let underlineBuffer = buffer.assumingMemoryBound(to: CompositionUnderlineLayout.self)
        let count = Int(vector.size)
        var patchedCount = 0
        var inlineCount = 0
        for index in 0..<count {
            var underline = underlineBuffer.advanced(by: index).pointee
            guard underline.isInlineColor else {
                continue
            }
            inlineCount += 1
            underline.compositionUnderlineColor = 0
            underline.colorAndFlags = (underline.colorAndFlags & ~UInt64(0xFFFF_FFFF)) | UInt64(underlineRGBA)
            underlineBuffer.advanced(by: index).pointee = underline
            patchedCount += 1
        }
        if debugEnabled && !didLogRewrite {
            didLogRewrite = true
            debugLog("rewriteUnderlines size=\(count) inline=\(inlineCount) patched=\(patchedCount)")
        }
    }

    private static func packedSRGB(_ color: UIColor) -> UInt32 {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return 0xFF95_00FF
        }
        return (UInt32(clampByte(red)) << 24)
            | (UInt32(clampByte(green)) << 16)
            | (UInt32(clampByte(blue)) << 8)
            | UInt32(clampByte(alpha))
    }

    private static func clampByte(_ value: CGFloat) -> UInt8 {
        let clamped = max(0, min(1, value))
        return UInt8((clamped * 255).rounded())
    }

    private static func debugLog(_ message: String) {
        guard debugEnabled else {
            return
        }
        NSLog("IMEUnderlineHook: %@", message)
    }
}

private struct VectorLayout {
    var buffer: UnsafeMutableRawPointer?
    var capacity: UInt32
    var size: UInt32

    static var isExpectedLayout: Bool {
        MemoryLayout<VectorLayout>.size == 16
            && MemoryLayout<VectorLayout>.alignment == MemoryLayout<UnsafeRawPointer>.alignment
    }
}

private struct CompositionUnderlineLayout {
    var startOffset: UInt32
    var endOffset: UInt32
    var compositionUnderlineColor: UInt8
    var padding0: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var colorAndFlags: UInt64
    var thick: UInt8
    var padding1: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    static var isExpectedLayout: Bool {
        MemoryLayout<CompositionUnderlineLayout>.size == 32
            && MemoryLayout<CompositionUnderlineLayout>.alignment == 8
    }

    var isInlineColor: Bool {
        let flagsShift: UInt64 = 48
        let flags = (colorAndFlags >> flagsShift) & 0xFF
        let validBit: UInt64 = 1 << 2
        let outOfLineBit: UInt64 = 1 << 3
        return (flags & validBit) != 0 && (flags & outOfLineBit) == 0
    }
}
#else
enum IMEUnderlineHook {
    static func install() {
    }
}
#endif

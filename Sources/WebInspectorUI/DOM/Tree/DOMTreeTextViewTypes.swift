#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
struct DOMTreeLine {
    let node: DOMNode
    let depth: Int
    let rowIndex: Int
    let text: String
    let textRange: NSRange
    let markupRange: NSRange
    let tokens: [DOMTreeToken]
    let displayColumnCount: Int
    let hasDisclosure: Bool
    let isOpen: Bool
    let isClosingTag: Bool

    func hasSameRenderedContent(as other: DOMTreeLine) -> Bool {
        node.id == other.node.id
            && depth == other.depth
            && text == other.text
            && tokens == other.tokens
            && displayColumnCount == other.displayColumnCount
            && hasDisclosure == other.hasDisclosure
            && isOpen == other.isOpen
            && isClosingTag == other.isClosingTag
    }

    func offsettingTextRange(by delta: Int) -> DOMTreeLine {
        DOMTreeLine(
            node: node,
            depth: depth,
            rowIndex: rowIndex,
            text: text,
            textRange: NSRange(location: textRange.location + delta, length: textRange.length),
            markupRange: markupRange,
            tokens: tokens,
            displayColumnCount: displayColumnCount,
            hasDisclosure: hasDisclosure,
            isOpen: isOpen,
            isClosingTag: isClosingTag
        )
    }
}

struct DOMTreeToken: Equatable {
    let kind: DOMTreeTokenKind
    let range: NSRange
}

struct DOMTreeRowDiff {
    let previousStart: Int
    let previousEnd: Int
    let nextStart: Int
    let nextEnd: Int
}

enum DOMTreeInvalidation: Equatable {
    case documentReset
    case structural(affectedKeys: Set<DOMNode.ID>)
    case content(affectedKeys: Set<DOMNode.ID>)
}

struct DOMTreeMarkupSignature: Hashable {
    let nodeType: DOMNodeType
    let nodeName: String
    let localName: String
    let nodeValue: String
    let pseudoType: String?
    let shadowRootType: String?
    let isTemplateContent: Bool
    let attributes: [DOMAttribute]
    let childCount: Int
    let hasDisclosure: Bool
    let isOpen: Bool
    let isClosingTag: Bool
}

struct DOMTreeCachedMarkup {
    let signature: DOMTreeMarkupSignature
    let markup: DOMTreeMarkup
}

enum DOMTreeTokenKind: String {
    case punctuation
    case tagName
    case attributeName
    case attributeValue
    case text
    case comment
    case doctype
    case fallback

    @MainActor
    func color(resolvedFor traitCollection: UITraitCollection) -> UIColor {
        let theme = DOMTreeHighlightTheme.webInspector
        let dynamicColor = switch self {
        case .punctuation:
            theme.tagPunctuation
        case .tagName:
            theme.nodeName
        case .attributeName:
            theme.nodeAttribute
        case .attributeValue:
            theme.nodeValue
        case .text:
            theme.textSecondary
        case .comment:
            theme.textSecondary
        case .doctype:
            theme.nodeAttribute
        case .fallback:
            theme.textSecondary
        }
        return dynamicColor.resolvedColor(with: traitCollection)
    }
}

@MainActor
struct DOMTreeResolvedTextAttributes {
    let userInterfaceStyle: UIUserInterfaceStyle
    let base: [NSAttributedString.Key: Any]
    let tokenColors: [DOMTreeTokenKind: UIColor]

    init(traitCollection: UITraitCollection) {
        userInterfaceStyle = traitCollection.userInterfaceStyle
        let theme = DOMTreeHighlightTheme.webInspector
        base = [
            .font: DOMTreeTextView.font,
            .paragraphStyle: DOMTreeTextView.paragraphStyle,
            .baselineOffset: DOMTreeTextView.textBaselineOffset,
            .foregroundColor: theme.baseForeground.resolvedColor(with: traitCollection)
        ]
        tokenColors = [
            .punctuation: theme.tagPunctuation.resolvedColor(with: traitCollection),
            .tagName: theme.nodeName.resolvedColor(with: traitCollection),
            .attributeName: theme.nodeAttribute.resolvedColor(with: traitCollection),
            .attributeValue: theme.nodeValue.resolvedColor(with: traitCollection),
            .text: theme.textSecondary.resolvedColor(with: traitCollection),
            .comment: theme.textSecondary.resolvedColor(with: traitCollection),
            .doctype: theme.nodeAttribute.resolvedColor(with: traitCollection),
            .fallback: theme.textSecondary.resolvedColor(with: traitCollection)
        ]
    }
}

struct DOMTreeHighlightTheme {
    let baseForeground: UIColor
    let textSecondary: UIColor
    let textTertiary: UIColor
    let nodeName: UIColor
    let nodeAttribute: UIColor
    let nodeValue: UIColor
    let tagPunctuation: UIColor
    let disclosure: UIColor
    let selectedRowBackground: UIColor
    let hoverRowBackground: UIColor
    let findBackground: UIColor
    let currentFindBackground: UIColor

    static let webInspector = DOMTreeHighlightTheme(
        baseForeground: .domTreeDynamic(light: 0x111827, dark: 0xF7F9FC),
        textSecondary: .domTreeDynamic(light: 0x475569, dark: 0xA0AFC1),
        textTertiary: .domTreeDynamic(light: 0x6B7280, dark: 0x6E7A88),
        nodeName: .domTreeDynamic(light: 0x0F6BDC, dark: 0x32D4FF),
        nodeAttribute: .domTreeDynamic(light: 0x8A2EC3, dark: 0xEC9EFF),
        nodeValue: .domTreeDynamic(light: 0xB35C00, dark: 0xFFD479),
        tagPunctuation: .domTreeDynamic(light: 0x0F6BDC, dark: 0x32D4FF),
        disclosure: .systemGray,
        selectedRowBackground: .domTreeDynamic(light: 0x0A84FF, dark: 0x0A84FF, lightAlpha: 0.18, darkAlpha: 0.35),
        hoverRowBackground: .domTreeDynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.05),
        findBackground: .domTreeDynamic(light: 0xFFC947, dark: 0xFFDB73, lightAlpha: 0.42, darkAlpha: 0.35),
        currentFindBackground: .domTreeDynamic(light: 0xFFC947, dark: 0xFFDB73, lightAlpha: 0.62, darkAlpha: 0.52)
    )
}

extension DOMTreeInvalidation {
    var requiresImmediateReload: Bool {
        if case .documentReset = self {
            return true
        }
        return false
    }

    var requiresTextFragmentReset: Bool {
        if case .documentReset = self {
            return true
        }
        return false
    }

    func merged(with other: DOMTreeInvalidation) -> DOMTreeInvalidation {
        switch (self, other) {
        case (.documentReset, _), (_, .documentReset):
            return .documentReset
        case let (.structural(lhs), .structural(rhs)),
             let (.structural(lhs), .content(rhs)),
             let (.content(lhs), .structural(rhs)):
            return .structural(affectedKeys: lhs.union(rhs))
        case let (.content(lhs), .content(rhs)):
            return .content(affectedKeys: lhs.union(rhs))
        }
    }
}

struct DisclosureSymbolImageCacheKey: Hashable {
    let userInterfaceStyle: UIUserInterfaceStyle
    let isOpen: Bool
}

extension CGRect {
    func wiIsNearlyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        origin.x.wiIsNearlyEqual(to: other.origin.x, tolerance: tolerance)
            && origin.y.wiIsNearlyEqual(to: other.origin.y, tolerance: tolerance)
            && size.wiIsNearlyEqual(to: other.size, tolerance: tolerance)
    }
}

extension CGSize {
    func wiIsNearlyEqual(to other: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        width.wiIsNearlyEqual(to: other.width, tolerance: tolerance)
            && height.wiIsNearlyEqual(to: other.height, tolerance: tolerance)
    }
}

extension CGFloat {
    func wiIsNearlyEqual(to other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}

private extension UIColor {
    static func domTreeDynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1.0, darkAlpha: CGFloat = 1.0) -> UIColor {
        UIColor { traitCollection in
            let isDark = traitCollection.userInterfaceStyle == .dark
            return domTreeColor(
                hex: isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }

    static func domTreeColor(hex: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif

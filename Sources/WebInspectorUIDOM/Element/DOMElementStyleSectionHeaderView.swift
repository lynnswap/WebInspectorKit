#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

package enum DOMElementStyleSectionHeaderText {
    private static let largeColumnNumber = 80

    package struct SourceLocation: Equatable, Sendable {
        /// Zero-based source line, matching WebKit source location values.
        package var sourceURL: String
        package var line: Int
        /// Zero-based source column when the rule provides one.
        package var column: Int?

        package init(sourceURL: String, line: Int, column: Int? = nil) {
            self.sourceURL = sourceURL
            self.line = line
            self.column = column
        }
    }

    package static func displayOriginText(for rule: CSSStyleRule) -> String? {
        if let sourceLocation = sourceLocation(for: rule) {
            return displayText(for: sourceLocation)
        }
        return displayText(for: rule.origin)
    }

    package static func accessibilityOriginText(for rule: CSSStyleRule) -> String? {
        if let sourceLocation = sourceLocation(for: rule) {
            return fullDisplayText(for: sourceLocation)
        }
        return displayText(for: rule.origin)
    }

    /// Source location from what `CSSStyleRule` carries directly: the selector
    /// range when present, otherwise the rule's reported source line.
    /// Stylesheet-header offsets are not applied (no header registry yet).
    package static func sourceLocation(for rule: CSSStyleRule) -> SourceLocation? {
        guard let sourceURL = rule.sourceURL, !sourceURL.isEmpty else {
            return nil
        }
        if let selectorRange = rule.selectorRange {
            return SourceLocation(
                sourceURL: sourceURL,
                line: selectorRange.startLine,
                column: selectorRange.startColumn
            )
        }
        guard let sourceLine = rule.sourceLine else {
            return nil
        }
        return SourceLocation(sourceURL: sourceURL, line: sourceLine, column: nil)
    }

    package static func displayText(for sourceLocation: SourceLocation) -> String {
        var text = displayName(forSourceURL: sourceLocation.sourceURL)
        text += ":\(sourceLocation.line + 1)"
        if let column = sourceLocation.column, column > largeColumnNumber {
            text += ":\(column + 1)"
        }
        return text
    }

    package static func fullDisplayText(for sourceLocation: SourceLocation) -> String {
        var text = sourceLocation.sourceURL
        text += ":\(sourceLocation.line + 1)"
        if let column = sourceLocation.column {
            text += ":\(column + 1)"
        }
        return text
    }

    package static func displayName(forSourceURL sourceURL: String) -> String {
        guard !sourceURL.hasPrefix("data:") else {
            return sourceURL
        }

        guard let components = URLComponents(string: sourceURL) else {
            return sourceURL
        }

        let path = components.percentEncodedPath
        if let encodedName = path.split(separator: "/", omittingEmptySubsequences: true).last {
            let name = String(encodedName)
            return name.removingPercentEncoding ?? name
        }

        if let host = components.host, !host.isEmpty {
            return host
        }

        return sourceURL
    }

    package static func displayText(for origin: CSSStyleRule.Origin) -> String? {
        switch origin.rawValue {
        case "user":
            String(localized: "dom.element.styles.origin.user", bundle: WebInspectorUILocalization.bundle)
        case "user-agent":
            String(localized: "dom.element.styles.origin.user_agent", bundle: WebInspectorUILocalization.bundle)
        case "author":
            String(localized: "dom.element.styles.origin.author", bundle: WebInspectorUILocalization.bundle)
        case "inspector":
            String(localized: "dom.element.styles.origin.inspector", bundle: WebInspectorUILocalization.bundle)
        default:
            origin.rawValue.isEmpty ? nil : origin.rawValue
        }
    }
}

@MainActor
final class DOMElementStyleSectionHeaderView: UICollectionViewListCell {
    private var renderedTitle = ""
    private var renderedOriginText: String?
    private var renderedAccessibilityOriginText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bind(nil)
    }

    /// Sections are value types: the header renders the configured value
    /// once and is re-bound by the view controller when the section's
    /// rendered content changes.
    func bind(_ section: CSSStyleSection?) {
        render(section)
    }

    private func render(_ section: CSSStyleSection?) {
        renderedTitle = section?.title ?? ""
        renderedOriginText = section?.rule.flatMap(DOMElementStyleSectionHeaderText.displayOriginText(for:))
        renderedAccessibilityOriginText = section?.rule.flatMap(DOMElementStyleSectionHeaderText.accessibilityOriginText(for:))

        var content = defaultContentConfiguration()
        content.text = renderedTitle
        content.secondaryText = renderedOriginText
        content.secondaryTextProperties.color = .secondaryLabel
        contentConfiguration = content

        let accessibilityLabel = [renderedTitle, renderedAccessibilityOriginText]
            .compactMap { text in
                guard let text, !text.isEmpty else {
                    return nil
                }
                return text
            }
            .joined(separator: ", ")
        isAccessibilityElement = accessibilityLabel.isEmpty == false
        self.accessibilityLabel = accessibilityLabel.isEmpty ? nil : accessibilityLabel
    }
}

#if DEBUG
extension DOMElementStyleSectionHeaderView {
    package var titleTextForTesting: String {
        renderedTitle
    }

    package var originTextForTesting: String? {
        renderedOriginText
    }
}
#endif
#endif

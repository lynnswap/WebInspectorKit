#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

package enum DOMElementStyleSectionHeaderText {
    private static let largeColumnNumber = 80

    package static func displayOriginText(for rule: CSSRule) -> String? {
        if let sourceLocation = rule.sourceLocation {
            return displayText(for: sourceLocation)
        }
        return displayText(for: rule.origin)
    }

    package static func accessibilityOriginText(for rule: CSSRule) -> String? {
        if let sourceLocation = rule.sourceLocation {
            return fullDisplayText(for: sourceLocation)
        }
        return displayText(for: rule.origin)
    }

    package static func displayText(for sourceLocation: CSSRule.SourceLocation) -> String {
        var text = displayName(forSourceURL: sourceLocation.sourceURL)
        text += ":\(sourceLocation.line + 1)"
        if let column = sourceLocation.column, column > largeColumnNumber {
            text += ":\(column + 1)"
        }
        return text
    }

    package static func fullDisplayText(for sourceLocation: CSSRule.SourceLocation) -> String {
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

    package static func displayText(for origin: CSSStyle.Origin) -> String? {
        switch origin {
        case .user:
            String(localized: "dom.element.styles.origin.user", bundle: .module)
        case .userAgent:
            String(localized: "dom.element.styles.origin.user_agent", bundle: .module)
        case .author:
            String(localized: "dom.element.styles.origin.author", bundle: .module)
        case .inspector:
            String(localized: "dom.element.styles.origin.inspector", bundle: .module)
        case let .other(value):
            value.isEmpty ? nil : value
        }
    }
}

@MainActor
final class DOMElementStyleSectionHeaderView: UICollectionViewListCell {
    private var sectionObservation: PortableObservationTracking.Token?
    private weak var section: CSSStyle.Section?
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

    isolated deinit {
        sectionObservation?.cancel()
    }

    func bind(_ section: CSSStyle.Section?) {
        guard let section else {
            sectionObservation?.cancel()
            sectionObservation = nil
            self.section = nil
            render(nil)
            return
        }

        if self.section === section {
            return
        }
        self.section = section
        sectionObservation?.cancel()
        sectionObservation = withPortableContinuousObservation { [weak self, weak section] _ in
            guard let self else {
                return
            }
            self.render(section)
        }
    }

    private func render(_ section: CSSStyle.Section?) {
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

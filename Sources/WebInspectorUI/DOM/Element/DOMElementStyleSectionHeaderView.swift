#if canImport(UIKit)
import WebInspectorCore
import SwiftUI
import UIKit

package enum DOMElementStyleSectionHeaderConfiguration {
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

    package static func displayText(for sourceLocation: CSSRuleSourceLocation) -> String {
        var text = displayName(forSourceURL: sourceLocation.sourceURL)
        text += ":\(sourceLocation.line + 1)"
        if let column = sourceLocation.column, column > largeColumnNumber {
            text += ":\(column + 1)"
        }
        return text
    }

    package static func fullDisplayText(for sourceLocation: CSSRuleSourceLocation) -> String {
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

    package static func displayText(for origin: CSSStyleOrigin) -> String? {
        switch origin {
        case .user:
            webInspectorLocalized("dom.element.styles.origin.user", default: "User Style Sheet")
        case .userAgent:
            webInspectorLocalized("dom.element.styles.origin.user_agent", default: "User Agent Style Sheet")
        case .author:
            webInspectorLocalized("dom.element.styles.origin.author", default: "Author Style Sheet")
        case .inspector:
            webInspectorLocalized("dom.element.styles.origin.inspector", default: "Web Inspector")
        case let .other(value):
            value.isEmpty ? nil : value
        }
    }
}

@MainActor
final class DOMElementStyleSectionHeaderView: UICollectionViewListCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        bind(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func bind(_ section: CSSStyleSection?) {
        contentConfiguration = UIHostingConfiguration {
            DOMElementStyleSectionHeaderContent(section: section)
        }
    }
}

private struct DOMElementStyleSectionHeaderContent: View {
    var section: CSSStyleSection?

    private var title: String {
        section?.title ?? ""
    }

    private var originText: String? {
        section?.rule.flatMap(DOMElementStyleSectionHeaderConfiguration.displayOriginText(for:))
    }

    private var accessibilityOriginText: String? {
        section?.rule.flatMap(DOMElementStyleSectionHeaderConfiguration.accessibilityOriginText(for:))
    }

    private var accessibilityLabel: String {
        [title, accessibilityOriginText]
            .compactMap { text in
                guard let text, !text.isEmpty else {
                    return nil
                }
                return text
            }
            .joined(separator: ", ")
    }

    var body: some View {
        LabeledContent {
            if let originText {
                Text(originText)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Text(title)
        }
        .textScale(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}
#endif

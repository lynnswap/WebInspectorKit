#if canImport(UIKit)
import Observation
import SwiftUI
import UIKit
import WebInspectorCore

@MainActor
@Observable
package final class DOMElementStyleSectionHeaderConfiguration {
    private static let largeColumnNumber = 80

    package var section: CSSStyleSection?

    package init(section: CSSStyleSection? = nil) {
        self.section = section
    }

    package var title: String {
        section?.title ?? ""
    }

    package var originText: String? {
        section?.rule.flatMap(Self.displayOriginText(for:))
    }

    package var accessibilityOriginText: String? {
        section?.rule.flatMap(Self.accessibilityOriginText(for:))
    }

    package var accessibilityLabel: String {
        [title, accessibilityOriginText]
            .compactMap { text in
                guard let text, !text.isEmpty else {
                    return nil
                }
                return text
            }
            .joined(separator: ", ")
    }

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
    private let headerConfiguration = DOMElementStyleSectionHeaderConfiguration()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentConfiguration = UIHostingConfiguration {
            DOMElementStyleSectionHeaderContent(configuration: headerConfiguration)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func bind(_ section: CSSStyleSection?) {
        headerConfiguration.section = section
    }
}

private struct DOMElementStyleSectionHeaderContent: View {
    var configuration: DOMElementStyleSectionHeaderConfiguration

    var body: some View {
        LabeledContent {
            if let originText = configuration.originText {
                Text(originText)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Text(configuration.title)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(configuration.accessibilityLabel)
    }
}
#endif

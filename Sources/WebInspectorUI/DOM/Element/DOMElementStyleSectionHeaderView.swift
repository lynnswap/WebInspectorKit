#if canImport(UIKit)
import WebInspectorCore
import Observation
import SwiftUI
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
    private let model = DOMElementStyleSectionHeaderModel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let model = model
        contentConfiguration = UIHostingConfiguration {
            DOMElementStyleSectionHeaderContent(model: model)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bind(nil)
    }

    func bind(_ section: CSSStyle.Section?) {
        model.section = section
    }
}

@MainActor
@Observable
private final class DOMElementStyleSectionHeaderModel {
    var section: CSSStyle.Section?
}

private struct DOMElementStyleSectionHeaderContent: View {
    var model: DOMElementStyleSectionHeaderModel

    private var title: String {
        model.section?.title ?? ""
    }

    private var originText: String? {
        model.section?.rule.flatMap(DOMElementStyleSectionHeaderText.displayOriginText(for:))
    }

    private var accessibilityOriginText: String? {
        model.section?.rule.flatMap(DOMElementStyleSectionHeaderText.accessibilityOriginText(for:))
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

#if DEBUG
extension DOMElementStyleSectionHeaderView {
    package var titleTextForTesting: String {
        model.titleTextForTesting
    }

    package var originTextForTesting: String? {
        model.originTextForTesting
    }
}

private extension DOMElementStyleSectionHeaderModel {
    var titleTextForTesting: String {
        section?.title ?? ""
    }

    var originTextForTesting: String? {
        section?.rule.flatMap(DOMElementStyleSectionHeaderText.displayOriginText(for:))
    }
}
#endif
#endif

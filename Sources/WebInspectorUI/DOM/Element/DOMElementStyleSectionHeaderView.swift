#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore

package struct DOMElementStyleSectionHeaderPresentation: Equatable {
    private static let largeColumnNumber = 80

    package var title: String
    package var originText: String?
    package var accessibilityOriginText: String?

    package init(section: CSSStyleSection) {
        title = section.title
        originText = section.rule.flatMap(Self.displayOriginText(for:))
        accessibilityOriginText = section.rule.flatMap(Self.accessibilityOriginText(for:))
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
final class DOMElementStyleSectionHeaderView: UICollectionReusableView {
    private let observationScope = ObservationScope()
    private let titleLabel = UILabel()
    private let originLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }

    func bind(_ section: CSSStyleSection) {
        render(section)

        observationScope.cancelAll()
        observationScope.observe(section) { [weak self] _, section in
            self?.render(section)
        }
    }

    func clear() {
        observationScope.cancelAll()
        titleLabel.text = nil
        originLabel.text = nil
        originLabel.isHidden = true
        accessibilityLabel = nil
    }

    private func configureStaticViews() {
        preservesSuperviewLayoutMargins = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        originLabel.translatesAutoresizingMaskIntoConstraints = false
        originLabel.font = .preferredFont(forTextStyle: .caption1)
        originLabel.textColor = .tertiaryLabel
        originLabel.textAlignment = .right
        originLabel.adjustsFontForContentSizeCategory = true
        originLabel.numberOfLines = 1
        originLabel.lineBreakMode = .byTruncatingTail
        originLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        originLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        originLabel.isHidden = true

        addSubview(titleLabel)
        addSubview(originLabel)

        let layoutGuide = layoutMarginsGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: layoutGuide.leadingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: layoutGuide.bottomAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: originLabel.leadingAnchor, constant: -8),

            originLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            originLabel.trailingAnchor.constraint(equalTo: layoutGuide.trailingAnchor),
            originLabel.widthAnchor.constraint(lessThanOrEqualTo: layoutGuide.widthAnchor, multiplier: 0.55),
        ])
    }

    private func render(_ section: CSSStyleSection) {
        let presentation = DOMElementStyleSectionHeaderPresentation(section: section)
        titleLabel.text = presentation.title
        originLabel.text = presentation.originText
        originLabel.isHidden = presentation.originText?.isEmpty != false
        accessibilityLabel = presentation.accessibilityLabel
    }
}

#if DEBUG
extension DOMElementStyleSectionHeaderView {
    package var titleTextForTesting: String? {
        titleLabel.text
    }

    package var originTextForTesting: String? {
        originLabel.text
    }

    package var titleNumberOfLinesForTesting: Int {
        titleLabel.numberOfLines
    }

    package var originNumberOfLinesForTesting: Int {
        originLabel.numberOfLines
    }

    package var titleLineBreakModeForTesting: NSLineBreakMode {
        titleLabel.lineBreakMode
    }

    package var originLineBreakModeForTesting: NSLineBreakMode {
        originLabel.lineBreakMode
    }
}
#endif
#endif

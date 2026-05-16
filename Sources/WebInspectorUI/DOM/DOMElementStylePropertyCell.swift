#if canImport(UIKit)
import UIKit
import WebInspectorCore

@MainActor
package final class DOMElementStylePropertyCell: UICollectionViewListCell {
    private let toggleButton = UIButton(type: .system)
    private let declarationStack = UIStackView()
    private let nameLabel = UILabel()
    private let colonLabel = UILabel()
    private let valueLabel = UILabel()
    private let annotationLabel = UILabel()
    private var propertyID: CSSPropertyIdentifier?
    private var nextEnabledState: Bool?
    private var toggleAction: ((CSSPropertyIdentifier, Bool) -> Void)?
    private var currentPropertyName: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }

    package func bind(
        property: CSSProperty,
        section: CSSStyleSection,
        isPending: Bool,
        canToggle: Bool,
        toggleAction: @escaping (CSSPropertyIdentifier, Bool) -> Void
    ) {
        currentPropertyName = property.name
        propertyID = property.id
        nextEnabledState = !property.isEnabled
        self.toggleAction = toggleAction

        let isToggleEnabled = canToggle && property.isEditable && property.id != nil && isPending == false
        toggleButton.isEnabled = isToggleEnabled
        toggleButton.setImage(toggleImage(isEnabled: property.isEnabled), for: .normal)
        toggleButton.tintColor = isToggleEnabled ? .secondaryLabel : .tertiaryLabel
        toggleButton.accessibilityLabel = String(
            format: webInspectorLocalized("dom.element.styles.toggle_property", default: "Toggle %@"),
            property.name
        )
        toggleButton.accessibilityValue = property.isEnabled
            ? webInspectorLocalized("enabled", default: "Enabled")
            : webInspectorLocalized("disabled", default: "Disabled")

        let displayState = DisplayState(property: property, isPending: isPending)
        nameLabel.attributedText = attributedText(
            property.name,
            font: Self.propertyNameFont,
            color: displayState.nameColor,
            strikethrough: displayState.usesStrikethrough
        )
        colonLabel.attributedText = attributedText(
            ":",
            font: Self.propertyValueFont,
            color: displayState.punctuationColor,
            strikethrough: displayState.usesStrikethrough
        )
        valueLabel.attributedText = attributedText(
            property.value,
            font: Self.propertyValueFont,
            color: displayState.valueColor,
            strikethrough: displayState.usesStrikethrough
        )
        annotationLabel.text = annotationText(for: property, isPending: isPending)
        annotationLabel.textColor = displayState.annotationColor

        accessibilityIdentifier = "WebInspector.DOM.Element.StyleProperty.\(property.name)"
        accessibilityLabel = accessibilityLabel(for: property, section: section)
        accessibilityValue = accessibilityValue(for: property, isPending: isPending)
    }

    package func clear() {
        propertyID = nil
        nextEnabledState = nil
        toggleAction = nil
        currentPropertyName = nil
        toggleButton.isEnabled = false
        toggleButton.setImage(toggleImage(isEnabled: false), for: .normal)
        nameLabel.attributedText = nil
        colonLabel.attributedText = nil
        valueLabel.attributedText = nil
        annotationLabel.text = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    private func configureStaticViews() {
        contentView.preservesSuperviewLayoutMargins = true
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.contentHorizontalAlignment = .center
        toggleButton.contentVerticalAlignment = .center
        toggleButton.addTarget(self, action: #selector(toggleButtonTapped), for: .touchUpInside)

        declarationStack.translatesAutoresizingMaskIntoConstraints = false
        declarationStack.axis = .horizontal
        declarationStack.alignment = .firstBaseline
        declarationStack.spacing = 4

        for label in [nameLabel, colonLabel, valueLabel, annotationLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 1
        }
        nameLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.lineBreakMode = .byTruncatingMiddle
        annotationLabel.lineBreakMode = .byTruncatingTail
        annotationLabel.font = Self.annotationFont
        annotationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        declarationStack.addArrangedSubview(nameLabel)
        declarationStack.addArrangedSubview(colonLabel)
        declarationStack.addArrangedSubview(valueLabel)
        declarationStack.addArrangedSubview(annotationLabel)

        contentView.addSubview(toggleButton)
        contentView.addSubview(declarationStack)
        let layoutGuide = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: layoutGuide.leadingAnchor),
            toggleButton.centerYAnchor.constraint(equalTo: layoutGuide.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 28),
            toggleButton.heightAnchor.constraint(equalToConstant: 28),

            declarationStack.topAnchor.constraint(equalTo: layoutGuide.topAnchor, constant: 8),
            declarationStack.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 6),
            declarationStack.trailingAnchor.constraint(equalTo: layoutGuide.trailingAnchor),
            declarationStack.bottomAnchor.constraint(equalTo: layoutGuide.bottomAnchor, constant: -8),
        ])
    }

    @objc private func toggleButtonTapped() {
        guard let propertyID,
              let nextEnabledState,
              let toggleAction else {
            return
        }
        toggleAction(propertyID, nextEnabledState)
    }

    private func toggleImage(isEnabled: Bool) -> UIImage? {
        UIImage(systemName: isEnabled ? "checkmark.square" : "square")
    }

    private func annotationText(for property: CSSProperty, isPending: Bool) -> String? {
        var annotations: [String] = []
        if property.priority.isEmpty == false {
            annotations.append("!\(property.priority)")
        }
        if property.isParsed == false {
            annotations.append(webInspectorLocalized("dom.element.styles.invalid", default: "invalid"))
        }
        if property.isOverridden {
            annotations.append(webInspectorLocalized("dom.element.styles.overridden", default: "overridden"))
        }
        if property.isImplicit {
            annotations.append(webInspectorLocalized("dom.element.styles.implicit", default: "implicit"))
        }
        if isPending {
            annotations.append(webInspectorLocalized("dom.element.styles.updating", default: "updating"))
        }
        return annotations.isEmpty ? nil : annotations.joined(separator: " · ")
    }

    private func accessibilityLabel(for property: CSSProperty, section: CSSStyleSection) -> String {
        var text = "\(property.name): \(property.value)"
        if property.priority.isEmpty == false {
            text += " !\(property.priority)"
        }
        return "\(section.title), \(text)"
    }

    private func accessibilityValue(for property: CSSProperty, isPending: Bool) -> String {
        var states: [String] = [
            property.isEnabled
                ? webInspectorLocalized("enabled", default: "Enabled")
                : webInspectorLocalized("disabled", default: "Disabled"),
        ]
        if property.isEditable == false {
            states.append(webInspectorLocalized("dom.element.styles.not_editable", default: "Not editable"))
        }
        if property.isOverridden {
            states.append(webInspectorLocalized("dom.element.styles.overridden", default: "Overridden"))
        }
        if property.isParsed == false {
            states.append(webInspectorLocalized("dom.element.styles.invalid", default: "Invalid"))
        }
        if property.isImplicit {
            states.append(webInspectorLocalized("dom.element.styles.implicit", default: "Implicit"))
        }
        if isPending {
            states.append(webInspectorLocalized("dom.element.styles.updating", default: "Updating"))
        }
        return states.joined(separator: ", ")
    }

    private func attributedText(
        _ text: String,
        font: UIFont,
        color: UIColor,
        strikethrough: Bool
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static var propertyNameFont: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
    }

    private static var propertyValueFont: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .regular
            )
        )
    }

    private static var annotationFont: UIFont {
        UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .medium
            )
        )
    }

    private struct DisplayState {
        var nameColor: UIColor
        var punctuationColor: UIColor
        var valueColor: UIColor
        var annotationColor: UIColor
        var usesStrikethrough: Bool

        init(property: CSSProperty, isPending: Bool) {
            usesStrikethrough = property.isEnabled == false || property.isOverridden

            if isPending || property.isEnabled == false || property.isOverridden || property.isImplicit {
                nameColor = .secondaryLabel
                punctuationColor = .tertiaryLabel
                valueColor = .secondaryLabel
                annotationColor = .secondaryLabel
            } else if property.isParsed == false {
                nameColor = .systemRed
                punctuationColor = .systemRed
                valueColor = .systemRed
                annotationColor = .systemRed
            } else {
                nameColor = .systemPurple
                punctuationColor = .secondaryLabel
                valueColor = .label
                annotationColor = .secondaryLabel
            }
        }
    }
}

#if DEBUG
extension DOMElementStylePropertyCell {
    package var propertyNameForTesting: String? {
        currentPropertyName
    }

    package var toggleButtonForTesting: UIButton {
        toggleButton
    }

    package func performToggleForTesting() {
        toggleButtonTapped()
    }
}
#endif
#endif

#if canImport(UIKit)
import WebInspectorCore
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementStylePropertyView: UIView {
    package typealias ToggleAction = @MainActor (CSSPropertyIdentifier, Bool) -> Bool

    private let observationScope = ObservationScope()
    private let declarationTextView = UITextView()
    private let toggleSwitch = UISwitch()
    private var property: CSSProperty?
    private var toggleAction: ToggleAction?

    override package init(frame: CGRect) {
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

    package func bind(
        property: CSSProperty,
        onToggle: ToggleAction? = nil
    ) {
        self.property = property
        toggleAction = onToggle

        observationScope.cancelAll()
        observationScope.observe(property) { [weak self] _, property in
            self?.renderAll(from: property)
        }
    }

    package func clear() {
        observationScope.cancelAll()
        property = nil
        toggleAction = nil
        declarationTextView.attributedText = nil
        toggleSwitch.setOn(false, animated: false)
        toggleSwitch.isEnabled = false
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        toggleSwitch.accessibilityLabel = nil
    }

    private func configureStaticViews() {
        preservesSuperviewLayoutMargins = true

        declarationTextView.translatesAutoresizingMaskIntoConstraints = false
        declarationTextView.backgroundColor = .clear
        declarationTextView.font = .preferredFont(forTextStyle: .body)
        declarationTextView.isEditable = false
        declarationTextView.isSelectable = true
        declarationTextView.isScrollEnabled = false
        declarationTextView.adjustsFontForContentSizeCategory = true
        declarationTextView.textContainerInset = .zero
        declarationTextView.textContainer.lineFragmentPadding = 0
        declarationTextView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        declarationTextView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        declarationTextView.isAccessibilityElement = false

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        toggleSwitch.addTarget(self, action: #selector(toggleSwitchChanged), for: .valueChanged)
        toggleSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(declarationTextView)
        addSubview(toggleSwitch)

        let layoutGuide = layoutMarginsGuide
        NSLayoutConstraint.activate([
            declarationTextView.topAnchor.constraint(equalTo: layoutGuide.topAnchor),
            declarationTextView.leadingAnchor.constraint(equalTo: layoutGuide.leadingAnchor),
            declarationTextView.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),
            declarationTextView.bottomAnchor.constraint(equalTo: layoutGuide.bottomAnchor),

            toggleSwitch.trailingAnchor.constraint(equalTo: layoutGuide.trailingAnchor),
            toggleSwitch.centerYAnchor.constraint(equalTo: layoutGuide.centerYAnchor),
        ])
    }

    private func renderAll(from property: CSSProperty) {
        renderDeclaration(from: property)
        renderToggleState(from: property)
        renderToggleAccessibility(from: property)
        renderRowAccessibility(from: property)
    }

    private func renderDeclaration(from property: CSSProperty) {
        declarationTextView.attributedText = declarationText(for: property)
    }

    private func renderToggleState(from property: CSSProperty, animated: Bool = false) {
        toggleSwitch.setOn(property.isEnabled, animated: animated)
        toggleSwitch.isEnabled = canToggle(property)
    }

    private func renderToggleAccessibility(from property: CSSProperty) {
        toggleSwitch.accessibilityLabel = String(
            localized: LocalizedStringResource(
                "dom.element.styles.toggle_property.accessibility_label",
                defaultValue: "Toggle \(property.name)",
                bundle: .module
            )
        )
    }

    private func renderRowAccessibility(from property: CSSProperty) {
        accessibilityIdentifier = "WebInspector.DOM.Element.StyleProperty.\(property.name)"
        accessibilityLabel = accessibilityLabel(for: property)
        accessibilityValue = accessibilityValue(for: property)
    }

    @objc private func toggleSwitchChanged() {
        guard let property else {
            toggleSwitch.setOn(false, animated: false)
            return
        }

        let requestedEnabledState = toggleSwitch.isOn
        guard canToggle(property),
              requestedEnabledState != property.isEnabled,
              let propertyID = property.id else {
            toggleSwitch.setOn(property.isEnabled, animated: false)
            return
        }

        if toggleAction?(propertyID, requestedEnabledState) != true {
            toggleSwitch.setOn(property.isEnabled, animated: false)
        }
    }

    private func canToggle(_ property: CSSProperty) -> Bool {
        property.isEditable && property.id != nil && toggleAction != nil
    }

    private func declarationText(for property: CSSProperty) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: declarationTextView.font ?? .preferredFont(forTextStyle: .body),
            .foregroundColor: property.status == .disabled ? UIColor.secondaryLabel : UIColor.label,
        ]
        if property.isOverridden {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: declarationDisplayText(for: property), attributes: attributes)
    }

    private func declarationDisplayText(for property: CSSProperty) -> String {
        let declaration: String
        if property.status == .disabled {
            declaration = property.text ?? "/* \(declarationSourceText(for: property)) */"
        } else {
            declaration = property.text ?? declarationSourceText(for: property)
        }
        return normalizedSingleLineDeclaration(declaration)
    }

    private func declarationSourceText(for property: CSSProperty) -> String {
        var declaration = "\(property.name): \(property.value)"
        if !property.priority.isEmpty {
            declaration += " !\(property.priority)"
        }
        return declaration + ";"
    }

    private func normalizedSingleLineDeclaration(_ declaration: String) -> String {
        declaration
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func accessibilityLabel(for property: CSSProperty) -> String {
        declarationDisplayText(for: property)
    }

    private func accessibilityValue(for property: CSSProperty) -> String {
        var states = [
            property.isEnabled
                ? String(localized: "dom.element.styles.property_enabled.accessibility_value", bundle: .module)
                : String(localized: "dom.element.styles.property_disabled.accessibility_value", bundle: .module),
        ]
        if property.isEditable == false {
            states.append(String(localized: "dom.element.styles.not_editable.accessibility_value", bundle: .module))
        }
        if property.isOverridden {
            states.append(String(localized: "dom.element.styles.overridden.accessibility_value", bundle: .module))
        }
        return states.joined(separator: ", ")
    }

}

#Preview("CSS Property Rows") {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.spacing = 8
    stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    stackView.isLayoutMarginsRelativeArrangement = true

    for property in DOMElementStylePropertyViewPreviewData.makeProperties() {
        let row = DOMElementStylePropertyView()
        row.bind(property: property) { _, enabled in
            property.status = enabled ? .active : .disabled
            property.text = enabled
                ? DOMElementStylePropertyViewPreviewData.sourceText(for: property)
                : "/* \(DOMElementStylePropertyViewPreviewData.sourceText(for: property)) */"
            return true
        }
        stackView.addArrangedSubview(row)
    }

    return stackView
}

@MainActor
private enum DOMElementStylePropertyViewPreviewData {
    private static let styleID = CSSStyleIdentifier(styleSheetID: .init("preview"), ordinal: 0)

    static func sourceText(for property: CSSProperty) -> String {
        var text = "\(property.name): \(property.value)"
        if !property.priority.isEmpty {
            text += " !\(property.priority)"
        }
        return text + ";"
    }

    static func makeProperties() -> [CSSProperty] {
        [
            CSSProperty(
                id: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0),
                name: "margin",
                value: "0",
                text: "margin: 0;",
                status: .active,
                isEditable: true
            ),
            CSSProperty(
                id: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 1),
                name: "box-sizing",
                value: "border-box",
                text: "/* box-sizing: border-box; */",
                status: .disabled,
                isEditable: true
            ),
            CSSProperty(
                id: CSSPropertyIdentifier(styleID: styleID, propertyIndex: 2),
                name: "font-size",
                value: "12px",
                text: "font-size: 12px;",
                status: .inactive,
                isEditable: true
            ),
            CSSProperty(
                name: "margin-top",
                value: "0",
                implicit: true
            ),
        ]
    }
}

#if DEBUG
extension DOMElementStylePropertyView {
    package var declarationTextForTesting: String {
        declarationTextView.text
    }

    package var declarationFontForTesting: UIFont? {
        declarationTextView.font
    }

    package var isToggleOnForTesting: Bool {
        toggleSwitch.isOn
    }

    package var isToggleEnabledForTesting: Bool {
        toggleSwitch.isEnabled
    }

    package func tapToggleForTesting() {
        guard toggleSwitch.isEnabled else {
            return
        }
        toggleSwitch.setOn(!toggleSwitch.isOn, animated: false)
        toggleSwitchChanged()
    }
}
#endif
#endif

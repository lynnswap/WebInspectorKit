#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class DOMElementStylePropertyView: UIView {
    package typealias ToggleAction = @MainActor (CSSStyleProperty, Bool) async -> Bool

    private let declarationTextView = UITextView()
    private let toggleSwitch = UISwitch()
    private var property: CSSStyleProperty?
    private var toggleAction: ToggleAction?
    private var toggleTask: Task<Void, Never>?
    private var propertyObservation: PortableObservationTracking.Token?

    override package init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        propertyObservation?.cancel()
    }

    package func bind(
        property: CSSStyleProperty,
        onToggle: ToggleAction? = nil
    ) {
        if self.property !== property {
            // A submitted mutation is committed user work and outlives cell
            // reuse. Drop only this view's completion handle.
            toggleTask = nil
        }
        propertyObservation?.cancel()
        self.property = property
        toggleAction = onToggle
        propertyObservation = withPortableContinuousObservation { [weak self, weak property] _ in
            guard let self,
                  let property,
                  self.property === property else {
                return
            }
            self.renderAll(from: property)
        }
    }

    package func clear() {
        // Do not cancel an accepted mutation when the collection view reuses
        // its presentation cell.
        toggleTask = nil
        propertyObservation?.cancel()
        propertyObservation = nil
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

    private func renderAll(from property: CSSStyleProperty) {
        renderDeclaration(from: property)
        renderToggleState(from: property)
        renderToggleAccessibility(from: property)
        renderRowAccessibility(from: property)
    }

    private func renderDeclaration(from property: CSSStyleProperty) {
        declarationTextView.attributedText = declarationText(for: property)
    }

    private func renderToggleState(from property: CSSStyleProperty, animated: Bool = false) {
        if property.isMutationPending == false {
            toggleSwitch.setOn(property.isEnabled, animated: animated)
        }
        toggleSwitch.isEnabled = canToggle(property)
    }

    private func renderToggleAccessibility(from property: CSSStyleProperty) {
        toggleSwitch.accessibilityLabel = String(
            localized: LocalizedStringResource(
                "dom.element.styles.toggle_property.accessibility_label",
                defaultValue: "Toggle \(property.name)",
                bundle: WebInspectorUILocalization.bundle
            )
        )
    }

    private func renderRowAccessibility(from property: CSSStyleProperty) {
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
              requestedEnabledState != property.isEnabled else {
            toggleSwitch.setOn(property.isEnabled, animated: false)
            return
        }

        guard let toggleAction else {
            toggleSwitch.setOn(property.isEnabled, animated: false)
            return
        }
        toggleSwitch.isEnabled = false
        toggleTask = Task { @MainActor [weak self] in
            _ = await toggleAction(property, requestedEnabledState)
            guard let self,
                  self.property === property else {
                return
            }
            toggleTask = nil
            if let currentProperty = self.property {
                renderToggleState(from: currentProperty)
            }
        }
    }

    private func canToggle(_ property: CSSStyleProperty) -> Bool {
        property.isEditable
            && property.isMutationPending == false
            && toggleAction != nil
            && toggleTask == nil
    }

    private func declarationText(for property: CSSStyleProperty) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: declarationTextView.font ?? .preferredFont(forTextStyle: .body),
            .foregroundColor: property.status == .disabled ? UIColor.secondaryLabel : UIColor.label,
        ]
        if property.isOverridden {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: declarationDisplayText(for: property), attributes: attributes)
    }

    private func declarationDisplayText(for property: CSSStyleProperty) -> String {
        let declaration: String
        if property.status == .disabled {
            declaration = property.text ?? "/* \(declarationSourceText(for: property)) */"
        } else {
            declaration = property.text ?? declarationSourceText(for: property)
        }
        return normalizedSingleLineDeclaration(declaration)
    }

    private func declarationSourceText(for property: CSSStyleProperty) -> String {
        var declaration = "\(property.name): \(property.value)"
        if let priority = property.priority, !priority.isEmpty {
            declaration += " !\(priority)"
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

    private func accessibilityLabel(for property: CSSStyleProperty) -> String {
        declarationDisplayText(for: property)
    }

    private func accessibilityValue(for property: CSSStyleProperty) -> String {
        var states = [
            property.isEnabled
                ? String(localized: "dom.element.styles.property_enabled.accessibility_value", bundle: WebInspectorUILocalization.bundle)
                : String(localized: "dom.element.styles.property_disabled.accessibility_value", bundle: WebInspectorUILocalization.bundle),
        ]
        if property.isEditable == false {
            states.append(String(localized: "dom.element.styles.not_editable.accessibility_value", bundle: WebInspectorUILocalization.bundle))
        }
        if property.isOverridden {
            states.append(String(localized: "dom.element.styles.overridden.accessibility_value", bundle: WebInspectorUILocalization.bundle))
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
        row.bind(property: property)
        stackView.addArrangedSubview(row)
    }

    return stackView
}

@MainActor
private enum DOMElementStylePropertyViewPreviewData {
    static func makeProperties() -> [CSSStyleProperty] {
        [
            CSSStyleProperty(
                id: CSSStyleProperty.ID("preview-margin"),
                name: "margin",
                value: "0",
                text: "margin: 0;",
                status: .active,
                isEditable: true
            ),
            CSSStyleProperty(
                id: CSSStyleProperty.ID("preview-box-sizing"),
                name: "box-sizing",
                value: "border-box",
                text: "/* box-sizing: border-box; */",
                status: .disabled,
                isEditable: true
            ),
            CSSStyleProperty(
                id: CSSStyleProperty.ID("preview-font-size"),
                name: "font-size",
                value: "12px",
                text: "font-size: 12px;",
                status: .inactive,
                isEditable: true
            ),
            CSSStyleProperty(
                id: CSSStyleProperty.ID("preview-margin-top"),
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

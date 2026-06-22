#if canImport(UIKit)
import WebInspectorUIBase
import UIKit

@MainActor
package final class DOMElementStyleHiddenVariablesCollectionCell: UICollectionViewListCell {
    private let revealButton = UIButton(type: .system)
    private var onReveal: (() -> Void)?

    override package init(frame: CGRect) {
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

    package func bind(hiddenVariableCount: Int, onReveal: @escaping () -> Void) {
        let title = Self.title(forHiddenVariableCount: hiddenVariableCount)
        self.onReveal = onReveal
        revealButton.setTitle(title, for: .normal)
        revealButton.accessibilityLabel = title
        revealButton.isEnabled = true
    }

    package func clear() {
        onReveal = nil
        revealButton.setTitle(nil, for: .normal)
        revealButton.accessibilityLabel = nil
        revealButton.isEnabled = false
    }

    private func configureStaticViews() {
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.accessibilityIdentifier = "WebInspector.DOM.Element.ShowUnusedCSSVariables"
        revealButton.addTarget(self, action: #selector(revealButtonPressed), for: .touchUpInside)
        contentView.addSubview(revealButton)

        NSLayoutConstraint.activate([
            revealButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            revealButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @objc private func revealButtonPressed() {
        // The reveal diff removes this pressed cell; disable first so UIKit does not keep it focusable.
        revealButton.isEnabled = false
        onReveal?()
    }

    private static func title(forHiddenVariableCount hiddenVariableCount: Int) -> String {
        var options = String.LocalizationOptions()
        options.replacements = [hiddenVariableCount]
        return String(
            localized: LocalizedStringResource(
                "Show \(placeholder: .int) unused CSS variables",
                bundle: .atURL(WebInspectorUILocalization.bundle.bundleURL)
            ),
            options: options
        )
    }
}

#if DEBUG
extension DOMElementStyleHiddenVariablesCollectionCell {
    package var isRevealButtonEnabledForTesting: Bool {
        revealButton.isEnabled
    }

    package func tapRevealForTesting() {
        revealButtonPressed()
    }
}
#endif
#endif

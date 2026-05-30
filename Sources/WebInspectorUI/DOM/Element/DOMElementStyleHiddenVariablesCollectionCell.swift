#if canImport(UIKit)
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
        onReveal?()
    }

    private static func title(forHiddenVariableCount hiddenVariableCount: Int) -> String {
        var options = String.LocalizationOptions()
        options.replacements = [hiddenVariableCount]
        return String(
            localized: "Show \(placeholder: .int) unused CSS variables",
            options: options,
            bundle: .module
        )
    }
}

#if DEBUG
extension DOMElementStyleHiddenVariablesCollectionCell {
    package func tapRevealForTesting() {
        revealButtonPressed()
    }
}
#endif
#endif

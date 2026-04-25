#if canImport(UIKit)
import UIKit
import WebInspectorEngine

final class V2_DOMElementAttributeCell: V2_DOMElementBaseCell {
    private let stackView = UIStackView()
    private let nameTextView = V2_DOMElementSelectableTextView(frame: .zero, textContainer: nil)
    private let valueTextView = V2_DOMElementSelectableTextView(frame: .zero, textContainer: nil)

    override var selectableTextViewsForSizing: [V2_DOMElementSelectableTextView] {
        [nameTextView, valueTextView]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTextViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameTextView.apply(text: "")
        valueTextView.apply(text: "")
    }

    func bind(_ attribute: DOMAttribute?) {
        accessories = []
        contentConfiguration = nil

        guard let attribute else {
            nameTextView.apply(text: "")
            valueTextView.apply(text: "")
            return
        }

        nameTextView.apply(text: attribute.name)
        valueTextView.apply(text: attribute.value)
    }

    private func configureTextViews() {
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 4
        contentView.addSubview(stackView)

        nameTextView.font = UIFont.preferredFont(forTextStyle: .body)
        nameTextView.textColor = .secondaryLabel

        valueTextView.font = Self.monospacedFootnoteFont
        valueTextView.textColor = .label

        stackView.addArrangedSubview(nameTextView)
        stackView.addArrangedSubview(valueTextView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}
#endif

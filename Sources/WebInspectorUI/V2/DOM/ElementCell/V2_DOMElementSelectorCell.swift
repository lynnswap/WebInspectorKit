#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine

final class V2_DOMElementSelectorCell: V2_DOMElementBaseCell {
    private let selectorTextView = V2_DOMElementSelectableTextView(frame: .zero, textContainer: nil)

    override var selectableTextViewForSizing: V2_DOMElementSelectableTextView? {
        selectorTextView
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSelectorTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        selectorTextView.apply(text: "")
    }

    func bind(node: DOMNodeModel) {
        resetObservationHandles()
        accessories = []
        contentConfiguration = nil

        store(
            node.observe(\.selectorPath) { [weak self] selectorPath in
                self?.render(selectorPath: selectorPath)
            }
        )
    }

    private func configureSelectorTextView() {
        selectorTextView.translatesAutoresizingMaskIntoConstraints = false
        selectorTextView.font = Self.monospacedFootnoteFont
        selectorTextView.textColor = .label
        contentView.addSubview(selectorTextView)

        NSLayoutConstraint.activate([
            selectorTextView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            selectorTextView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            selectorTextView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            selectorTextView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func render(selectorPath: String) {
        selectorTextView.apply(text: selectorPath)
    }
}
#endif

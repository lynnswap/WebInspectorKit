#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine

final class V2_DOMElementSelectorCell: V2_DOMElementBaseCell {
    private let selectorTextView = SelectableSelectorTextView(frame: .zero, textContainer: nil)

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
        selectorTextView.apply(text: "")

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

private final class SelectableSelectorTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }

    func apply(text: String) {
        guard self.text != text else {
            return
        }
        self.text = text
        invalidateIntrinsicContentSize()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}
#endif

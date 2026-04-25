#if canImport(UIKit)
import ObservationBridge
import UIKit

class V2_DOMElementBaseCell: UICollectionViewListCell {
    private static let minimumHeight: CGFloat = 44

    private var observationHandles: Set<ObservationHandle> = []

    var selectableTextViewForSizing: V2_DOMElementSelectableTextView? {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetObservationHandles()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        let targetWidth = attributes.size.width > 0 ? attributes.size.width : layoutAttributes.size.width
        guard targetWidth > 0 else {
            return attributes
        }

        if let selectableTextView = selectableTextViewForSizing {
            contentView.bounds.size.width = targetWidth
            contentView.setNeedsLayout()
            contentView.layoutIfNeeded()

            let textWidth = selectableTextView.bounds.width > 0
                ? selectableTextView.bounds.width
                : max(targetWidth - contentView.layoutMargins.left - contentView.layoutMargins.right, 1)
            let textHeight = selectableTextView.fittingHeight(for: textWidth)
            attributes.size.width = targetWidth
            attributes.size.height = max(
                Self.minimumHeight,
                attributes.size.height,
                ceil(textHeight + contentView.layoutMargins.top + contentView.layoutMargins.bottom)
            )
            return attributes
        }

        contentView.bounds.size.width = targetWidth
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()

        let fittingSize = contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size.width = targetWidth
        attributes.size.height = max(Self.minimumHeight, attributes.size.height, ceil(fittingSize.height))
        return attributes
    }

    func resetObservationHandles() {
        observationHandles.removeAll()
    }

    func store(_ observationHandle: ObservationHandle) {
        observationHandle.store(in: &observationHandles)
    }

    static var monospacedFootnoteFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
    }
}

final class V2_DOMElementSelectableTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            return super.intrinsicContentSize
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: measuredTextHeight(for: bounds.width))
    }

    override var bounds: CGRect {
        didSet {
            if oldValue.size != bounds.size {
                invalidateIntrinsicContentSize()
                updateVerticalTextInsets()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
        updateVerticalTextInsets()
    }

    func apply(text: String) {
        guard self.text != text else {
            return
        }
        self.text = text
        invalidateIntrinsicContentSize()
        updateVerticalTextInsets()
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        measuredTextHeight(for: width)
    }

    private func measuredTextHeight(for width: CGFloat) -> CGFloat {
        guard width > 0, let font else {
            return 0
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle,
            ],
            context: nil
        )
        return ceil(boundingRect.height)
    }

    private func updateVerticalTextInsets() {
        guard bounds.height > 0 else {
            return
        }

        let verticalInset = max(0, floor((bounds.height - measuredTextHeight(for: bounds.width)) / 2))
        let nextInsets = UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0)
        guard textContainerInset != nextInsets else {
            return
        }

        textContainerInset = nextInsets
        contentOffset = .zero
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byCharWrapping
        adjustsFontForContentSizeCategory = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }
}
#endif

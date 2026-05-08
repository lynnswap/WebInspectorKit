#if canImport(UIKit)
import ObservationBridge
import SyntaxEditorUI
import UIKit
import WebInspectorEngine

final class V2_DOMElementPreviewCell: V2_DOMElementBaseCell {
    private static let minimumHeight: CGFloat = 44

    private let previewModel = SyntaxEditorModel(
        text: "",
        language: .html,
        isEditable: false,
        lineWrappingEnabled: true
    )
    private lazy var previewEditorView = SyntaxEditorView(model: previewModel)
    private var layoutInvalidationTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurePreviewEditorView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layoutInvalidationTask?.cancel()
        render(displayPreviewText: "")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateVerticalTextInsets()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        let targetWidth = attributes.size.width > 0 ? attributes.size.width : layoutAttributes.size.width
        guard targetWidth > 0 else {
            return attributes
        }

        contentView.bounds.size.width = targetWidth
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()

        let textWidth = previewEditorView.bounds.width > 0
            ? previewEditorView.bounds.width
            : max(targetWidth - contentView.layoutMargins.left - contentView.layoutMargins.right, 1)
        let textHeight = fittingEditorHeight(for: textWidth)
        attributes.size.width = targetWidth
        attributes.size.height = max(
            Self.minimumHeight,
            attributes.size.height,
            ceil(textHeight + contentView.layoutMargins.top + contentView.layoutMargins.bottom)
        )
        return attributes
    }

    func bind(node: DOMNodeModel?) {
        accessories = []
        contentConfiguration = nil

        updateObservations {
            guard let node else {
                render(displayPreviewText: "")
                return
            }

            self.render(displayPreviewText: node.displayPreviewText)

            store(
                node.observe(\.displayPreviewText) { [weak self] displayPreviewText in
                    self?.render(displayPreviewText: displayPreviewText)
                }
            )
        }
    }

    private func configurePreviewEditorView() {
        previewEditorView.translatesAutoresizingMaskIntoConstraints = false
        previewEditorView.isEditable = false
        previewEditorView.isSelectable = true
        previewEditorView.isScrollEnabled = false
        previewEditorView.alwaysBounceVertical = false
        previewEditorView.backgroundColor = .clear
        previewEditorView.textContainerInset = .zero
        previewEditorView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewEditorView.setContentCompressionResistancePriority(.required, for: .vertical)
        previewEditorView.setContentHuggingPriority(.required, for: .vertical)
        contentView.addSubview(previewEditorView)

        NSLayoutConstraint.activate([
            previewEditorView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            previewEditorView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            previewEditorView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            previewEditorView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func render(displayPreviewText: String) {
        guard previewModel.text != displayPreviewText else {
            return
        }
        previewModel.text = displayPreviewText
        previewEditorView.invalidateIntrinsicContentSize()
        setNeedsLayout()
        scheduleLayoutInvalidation()
    }

    private func fittingEditorHeight(for width: CGFloat) -> CGFloat {
        guard width > 0 else {
            return 0
        }

        guard previewModel.text.isEmpty == false else {
            return ceil(previewEditorView.font.lineHeight)
        }

        let lineFragmentPadding = CGFloat(10)
        let textInsets = previewEditorView.textContainerInset
        let textWidth = max(1, width - textInsets.left - textInsets.right - lineFragmentPadding)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let textBounds = (previewModel.text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: previewEditorView.font,
                .paragraphStyle: paragraphStyle,
            ],
            context: nil
        )
        return max(ceil(previewEditorView.font.lineHeight), ceil(textBounds.height))
    }

    private func updateVerticalTextInsets() {
        guard previewEditorView.bounds.width > 0, previewEditorView.bounds.height > 0 else {
            return
        }

        let textHeight = fittingEditorHeight(for: previewEditorView.bounds.width)
        let verticalInset = max(0, floor((previewEditorView.bounds.height - textHeight) / 2))
        let nextInsets = UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0)
        guard previewEditorView.textContainerInset != nextInsets else {
            return
        }

        previewEditorView.textContainerInset = nextInsets
        previewEditorView.contentOffset = .zero
    }

    private func scheduleLayoutInvalidation() {
        layoutInvalidationTask?.cancel()
        layoutInvalidationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else {
                return
            }

            self.previewEditorView.invalidateIntrinsicContentSize()
            self.contentView.setNeedsLayout()
            self.setNeedsLayout()
            self.containingCollectionView?.collectionViewLayout.invalidateLayout()
        }
    }

    private var containingCollectionView: UICollectionView? {
        var candidate = superview
        while let view = candidate {
            if let collectionView = view as? UICollectionView {
                return collectionView
            }
            candidate = view.superview
        }
        return nil
    }
}

private extension DOMNodeModel {
    var displayPreviewText: String {
        switch nodeType {
        case .text:
            return trimmedNodeValue
        case .comment:
            return "<!-- \(trimmedNodeValue) -->"
        case .documentType:
            let name = displayNodeName.isEmpty ? "html" : displayNodeName
            return "<!DOCTYPE \(name)>"
        default:
            let attributes = attributes.map { attribute in
                "\(attribute.name)=\"\(attribute.value)\""
            }.joined(separator: " ")
            let suffix = attributes.isEmpty ? "" : " \(attributes)"
            return "<\(displayNodeName)\(suffix)>"
        }
    }

    private var displayNodeName: String {
        let name = localName.isEmpty ? nodeName : localName
        return name.lowercased()
    }

    private var trimmedNodeValue: String {
        nodeValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif

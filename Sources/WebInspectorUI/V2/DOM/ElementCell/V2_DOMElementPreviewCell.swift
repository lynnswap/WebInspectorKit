#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine

final class V2_DOMElementPreviewCell: V2_DOMElementBaseCell {
    private let previewTextView = V2_DOMElementSelectableTextView(frame: .zero, textContainer: nil)

    override var selectableTextViewsForSizing: [V2_DOMElementSelectableTextView] {
        [previewTextView]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurePreviewTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewTextView.apply(text: "")
    }

    func bind(node: DOMNodeModel?) {
        resetObservationHandles()
        accessories = []
        contentConfiguration = nil

        guard let node else {
            previewTextView.apply(text: "")
            return
        }
        
        self.render(displayPreviewText: node.displayPreviewText)
        
        store(
            node.observe(\.displayPreviewText) { [weak self] displayPreviewText in
                self?.render(displayPreviewText: displayPreviewText)
            }
        )
    }

    private func configurePreviewTextView() {
        previewTextView.translatesAutoresizingMaskIntoConstraints = false
        previewTextView.font = Self.monospacedFootnoteFont
        previewTextView.textColor = .label
        contentView.addSubview(previewTextView)

        NSLayoutConstraint.activate([
            previewTextView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            previewTextView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            previewTextView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            previewTextView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func render(displayPreviewText: String) {
        previewTextView.apply(text: displayPreviewText)
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

#if canImport(UIKit)
import UIKit

package struct NetworkCookieFieldContent: Hashable, Sendable {
    package let label: String
    package let value: String
    package let isFullWidth: Bool

    package init(label: String, value: String, isFullWidth: Bool = false) {
        self.label = label
        self.value = value
        self.isFullWidth = isFullWidth
    }
}

package struct NetworkCookieRowContent: Hashable, Sendable {
    package let fields: [NetworkCookieFieldContent]
    package let accessibilityIdentifier: String

    package init(
        fields: [NetworkCookieFieldContent],
        accessibilityIdentifier: String
    ) {
        self.fields = fields
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

@MainActor
package final class NetworkCookieCell: UICollectionViewListCell {
    private let fieldRows = UIStackView()
    private var rowContent: NetworkCookieRowContent?
    private var usesTwoColumns = false

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

    package func bind(_ content: NetworkCookieRowContent) {
        let contentChanged = rowContent != content
        rowContent = content
        accessibilityIdentifier = content.accessibilityIdentifier
        if contentChanged {
            rebuildFieldsIfNeeded(force: true)
        } else {
            rebuildFieldsIfNeeded(force: false)
        }
        renderAccessibility(content)
    }

    package func clear() {
        rowContent = nil
        usesTwoColumns = false
        removeAllArrangedSubviews(from: fieldRows)
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    private func configureStaticViews() {
        contentView.preservesSuperviewLayoutMargins = true
        fieldRows.axis = .vertical
        fieldRows.alignment = .fill
        fieldRows.spacing = 12
        fieldRows.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(fieldRows)
        NSLayoutConstraint.activate([
            fieldRows.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            fieldRows.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            fieldRows.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            fieldRows.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        registerForTraitChanges([
            UITraitHorizontalSizeClass.self,
            UITraitPreferredContentSizeCategory.self,
        ]) { (cell: NetworkCookieCell, _) in
            cell.rebuildFieldsIfNeeded(force: true)
        }
    }

    private func rebuildFieldsIfNeeded(force: Bool) {
        guard let rowContent else {
            removeAllArrangedSubviews(from: fieldRows)
            return
        }
        let nextUsesTwoColumns = traitCollection.horizontalSizeClass == .regular
            && traitCollection.preferredContentSizeCategory.isAccessibilityCategory == false
        guard force || usesTwoColumns != nextUsesTwoColumns else {
            return
        }
        usesTwoColumns = nextUsesTwoColumns
        removeAllArrangedSubviews(from: fieldRows)

        if nextUsesTwoColumns {
            installTwoColumnFields(rowContent.fields)
        } else {
            for field in rowContent.fields {
                fieldRows.addArrangedSubview(makeFieldView(field))
            }
        }
    }

    private func installTwoColumnFields(_ fields: [NetworkCookieFieldContent]) {
        var pendingFields: [NetworkCookieFieldContent] = []

        func flushPendingFields() {
            guard pendingFields.isEmpty == false else {
                return
            }
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 16
            for field in pendingFields {
                row.addArrangedSubview(makeFieldView(field))
            }
            if pendingFields.count == 1 {
                row.addArrangedSubview(UIView())
            }
            fieldRows.addArrangedSubview(row)
            pendingFields.removeAll(keepingCapacity: true)
        }

        for field in fields {
            if field.isFullWidth {
                flushPendingFields()
                fieldRows.addArrangedSubview(makeFieldView(field))
                continue
            }
            pendingFields.append(field)
            if pendingFields.count == 2 {
                flushPendingFields()
            }
        }
        flushPendingFields()
    }

    private func makeFieldView(_ field: NetworkCookieFieldContent) -> UIView {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = field.label
        label.isAccessibilityElement = false

        let value = UILabel()
        value.font = .preferredFont(forTextStyle: .body)
        value.textColor = .label
        value.adjustsFontForContentSizeCategory = true
        value.numberOfLines = 0
        value.lineBreakMode = .byCharWrapping
        value.text = field.value
        value.isAccessibilityElement = false

        let stack = UIStackView(arrangedSubviews: [label, value])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        return stack
    }

    private func renderAccessibility(_ content: NetworkCookieRowContent) {
        accessibilityLabel = content.fields
            .map { "\($0.label), \($0.value)" }
            .joined(separator: ", ")
        accessibilityValue = nil
    }

    private func removeAllArrangedSubviews(from stackView: UIStackView) {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

#if DEBUG
extension NetworkCookieCell {
    package var renderedFieldsForTesting: [NetworkCookieFieldContent] {
        rowContent?.fields ?? []
    }

    package var usesTwoColumnsForTesting: Bool {
        usesTwoColumns
    }

    package var fieldRowCountForTesting: Int {
        fieldRows.arrangedSubviews.count
    }
}
#endif
#endif

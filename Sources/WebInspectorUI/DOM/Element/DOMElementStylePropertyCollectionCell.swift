#if canImport(UIKit)
import UIKit
import WebInspectorCore

@MainActor
package final class DOMElementStylePropertyCollectionCell: UICollectionViewListCell {
    private let propertyView = DOMElementStylePropertyView()

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
        propertyView.clear()
    }

    package func bind(
        property: CSSProperty,
        onToggle: DOMElementStylePropertyView.ToggleAction?
    ) {
        propertyView.bind(
            property: property,
            onToggle: onToggle
        )
    }

    package func clear() {
        propertyView.clear()
    }

    private func configureStaticViews() {
        contentView.preservesSuperviewLayoutMargins = true
        propertyView.translatesAutoresizingMaskIntoConstraints = false
        propertyView.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)

        contentView.addSubview(propertyView)
        NSLayoutConstraint.activate([
            propertyView.topAnchor.constraint(equalTo: contentView.topAnchor),
            propertyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            propertyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            propertyView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
}

#if DEBUG
extension DOMElementStylePropertyCollectionCell {
    package var propertyViewForTesting: DOMElementStylePropertyView {
        propertyView
    }
}
#endif
#endif

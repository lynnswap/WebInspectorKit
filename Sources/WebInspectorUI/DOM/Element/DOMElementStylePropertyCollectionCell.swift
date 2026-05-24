#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore

@MainActor
package final class DOMElementStylePropertyCollectionCell: UICollectionViewListCell {
    private static let modifiedBackgroundColor = UIColor.systemGreen.withProminence(.quaternary).withAlphaComponent(0.99)

    private let observationScope = ObservationScope()
    private let propertyView = DOMElementStylePropertyView()
    private weak var property: CSSProperty?

    override package init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }

    override package func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)

        var background = defaultBackgroundConfiguration().updated(for: state)
        if property?.isModifiedByInspector == true {
            background.backgroundColor = Self.modifiedBackgroundColor
        }
        backgroundConfiguration = background
    }

    package func bind(
        property: CSSProperty,
        onToggle: DOMElementStylePropertyView.ToggleAction?
    ) {
        self.property = property
        propertyView.bind(
            property: property,
            onToggle: onToggle
        )
        setNeedsUpdateConfiguration()

        observationScope.update {
            property.observe(\.isModifiedByInspector) { [weak self] in
                self?.setNeedsUpdateConfiguration()
            }
            .store(in: observationScope)
        }
    }

    package func clear() {
        observationScope.cancelAll()
        property = nil
        propertyView.clear()
        setNeedsUpdateConfiguration()
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

    package var usesModifiedBackgroundForTesting: Bool {
        backgroundConfiguration?.backgroundColor == Self.modifiedBackgroundColor
    }
}
#endif
#endif
